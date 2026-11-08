# Conception 0.2 — `NOMADE-DATA` par défaut, `nomade-diag`, rapport de terrain

Statut : **proposition, à valider par Fabien** (2026-11-08). Rien n'est codé. Une fois validée, les
choix passent dans `DECISIONS.md` (D-046 et suivantes), `SPEC.md` (E-29 modifiée, E-44 et E-45
nouvelles) et `PLAN.md` ; cette note reste comme trace de la conception.

Données de terrain disponibles (`docs/JOURNAL.md`, 2026-11-08) :

| Clé | Puce (table Fabrique-Clé) | Pilote | Liaison | TRIM | Écriture `bmaptool` |
|---|---|---|---|---|---|
| SSK 1 To | `090c:2320` Silicon Motion SM2320, SSD USB natif | `uas` | 10 Gbit/s | oui | 560 Mio/s |
| SSK 128 Go | `2109:0715` VIA Labs VL715 (probablement) → SSD SATA | `usb-storage` (UAS ignoré par le noyau) | 10 Gbit/s | non (« Illegal Request ») | 225 Mio/s |

## En bref

| Sujet | Proposition |
|---|---|
| Taille de `NOMADE-DATA` | 10 % de la clé, au Gio inférieur, **plancher 8 Gio** ; `DEPLOY_DATA_GIB` force une taille, `0` supprime la partition |
| Montage | **`fstab`** par UUID, `/media/NOMADE-DATA`, `uid=1000`, `nofail` : accessible sans mot de passe, sans dépendre de polkit |
| Image | + `exfatprogs` (vérification au démarrage, déploiement depuis une clé nomade) |
| Langage de `nomade-diag` | **Python 3 (bibliothèque standard seule)**, réécrit ; on reprend de Fabrique-Clé la table des puces, le parcours sysfs et le protocole de mesure, pas le code Rust |
| Droits | partie « session » lancée en utilisateur, partie système par `sudo` (une seule saisie) |
| Anonymisation | par défaut : `resume.json` sur liste blanche, fichiers bruts nettoyés, numéros de série remplacés par une empreinte salée propre à la clé |
| Sortie | `nomade-diag-<date>-<modèle>.tar.zst` sur `NOMADE-DATA` (sinon `~/nomade-diag/`), `resume.json` à schéma versionné |
| Hôte | `make diag-rapport` : `diagnostics/archives/` (ignoré par git) → `diagnostics/resumes/*.json` et `docs/terrain.md` (versionnés) |

---

## 1. `NOMADE-DATA` active par défaut

### 1.1 Taille

Nouveaux paramètres dans `config/project.env` :

```bash
DEPLOY_DATA_PCT=10         # part de la clé pour NOMADE-DATA (exFAT, fin de clé) ; 0 : aucune
DEPLOY_DATA_MIN_GIB=8      # plancher quand la partition est créée
DEPLOY_DATA_GIB=           # vide : calculée ; > 0 : taille imposée ; 0 : aucune partition
```

Règle (fonction pure `data_gib` dans `scripts/lib.sh`, essayée par `make ci`) :

```
si DEPLOY_DATA_GIB est renseigné : taille = DEPLOY_DATA_GIB      (refus si la clé est trop petite)
sinon si DEPLOY_DATA_PCT = 0    : taille = 0
sinon                           : taille = max(⌊taille_clé_Gio × PCT / 100⌋, DEPLOY_DATA_MIN_GIB)
                                  et 0, avec un avertissement, si la racine passait sous
                                  IMAGE_ROOT_GIB + 16 Gio
```

| Clé | Capacité | `NOMADE-DATA` | Racine (≈) |
|---|---|---|---|
| fichier de `make deploy-test` | 64 Gio | 8 Gio (plancher) | 53 Gio |
| 64 Go | 59,6 Gio | 8 Gio (plancher) | 48 Gio |
| 128 Go (SSK) | 119,2 Gio | 11 Gio | 105 Gio |
| 256 Go | 238,4 Gio | 23 Gio | 212 Gio |
| 1 To (SSK) | 931,5 Gio | 93 Gio | 835 Gio (sans effet : pas de redéploiement) |

Pourquoi 8 Gio de plancher : avec 10 %, un plancher plus bas ne jouerait jamais (une clé de 32 Go ne
reçoit déjà pas l'image de 28 Gio) ; 8 Gio laisse de quoi échanger quelques ISO ou une sauvegarde de
documents sur une clé de 64 Go. Pas de plafond : 93 Gio sur 1 To restent raisonnables, et
`DEPLOY_DATA_GIB` est là pour qui veut autre chose.

`deploy-info` garde `DEPLOY_DATA_GIB` (taille **effective**, comme aujourd'hui : le contrôle
`root_fills_disk` de l'autotest ne change pas) et gagne `DEPLOY_DATA_PCT` pour mémoire. La clé de 1 To
(`DEPLOY_DATA_GIB=0`) reste cohérente.

### 1.2 Partition et système de fichiers

Inchangé : partition 4 en fin de clé, type GPT `0700` (données de base Microsoft), nom GPT et étiquette
exFAT `NOMADE-DATA` (11 caractères, le maximum exFAT), `mkfs.exfat` par défaut (grappes de 128 Kio
dans cette plage de tailles : du gaspillage pour de petits fichiers, sans importance pour une zone
d'échange). Pas d'option `discard` : `fstrim.timer` traite aussi les montages exFAT de `fstab`
(FITRIM pris en charge par le pilote exFAT du noyau), et ne fait rien sur un pont sans TRIM comme le
VL715.

Ajout de **`exfatprogs`** à l'image (≈ 0,3 Mo) :
- `fsck.exfat` au démarrage (passe 2 dans `fstab`) : l'exFAT est souvent arraché sans éjection sous
  Windows et garde son drapeau « sale » ;
- `deploy.sh` exige `mkfs.exfat` dès que la partition est créée, donc désormais par défaut : sans ce
  paquet, un déploiement lancé **depuis une clé nomade** échouerait.

### 1.3 Accès sans mot de passe administrateur : `fstab` plutôt qu'udisks

Deux voies :

- **udisks** (rien à écrire) : la partition apparaît dans Fichiers, l'utilisateur clique pour la monter.
  Pour un disque USB, udisks2 considère le disque comme amovible (`HintSystem=false`) et polkit autorise
  le montage par la session active sans mot de passe — à vérifier sur la clé, car c'est aussi le disque
  système. Inconvénients : montée seulement après un clic, sous `/media/fabien/NOMADE-DATA` ; un service
  ou `nomade-diag` lancé par root ne peut pas compter dessus.
- **`fstab`** (retenu) : montage au démarrage, chemin fixe, aucune dépendance à polkit. Ligne ajoutée
  par `deploy.sh` à la `fstab` de la cible (fichier produit par notre build, E-07 : rien à fusionner
  avec le squashfs) :

```
UUID=<numéro de volume exFAT>  /media/NOMADE-DATA  exfat  nofail,x-systemd.device-timeout=5s,noatime,uid=1000,gid=1000,dmask=0022,fmask=0133,errors=remount-ro,x-gvfs-show,x-gvfs-name=NOMADE-DATA  0  2
```

Par **UUID, pas par étiquette** : Fabien branche régulièrement une seconde clé nomade sur une clé en
marche ; deux `LABEL=NOMADE-DATA` rendraient le montage ambigu. `nofail` : une partition absente ou
abîmée ne bloque jamais le démarrage. `uid`/`gid` : l'exFAT n'a pas de droits, tout appartient à
l'utilisateur, y compris ce que root y écrit (archives de `nomade-diag`). `x-gvfs-show` : la partition
apparaît une seule fois dans la barre latérale de Fichiers. L'uid 1000 est celui que fixe le build
(`scripts/vm/build.sh`), lu dans la cible par `id -u "$TARGET_USER"` plutôt qu'écrit en dur.

### 1.4 Sur d'autres systèmes

Branchée sur un PC Windows, la clé ne montre que `NOMADE-DATA` (l'ESP est cachée, les types Linux sont
ignorés). macOS risque d'afficher « disque illisible » pour les partitions Linux : à constater, puis à
documenter dans le README (sans conséquence : il suffit d'ignorer le message).

### 1.5 Contrôles et tests

- Autotest, nouvelle exigence **E-44** (si `DEPLOY_DATA_GIB > 0` dans `deploy-info`) : partition 4
  d'étiquette `NOMADE-DATA` en exFAT, taille conforme à 1 Gio près, montée sur `/media/NOMADE-DATA`
  avec `uid=1000`, **écriture par l'utilisateur** (`runuser -u "$TARGET_USER" -- touch …`, puis
  effacement), entrée `fstab` par UUID. Sans partition (`make test` sur l'image nue) : contrôle sauté.
- `make deploy-test` : le fichier de 64 Gio reçoit 8 Gio (plancher) ; le premier passage le crée,
  le second vérifie qu'un redéploiement recrée la partition.
- `make ci` : `data_gib` pour 64, 119, 931 Gio, `DEPLOY_DATA_GIB=0`, `=20`, `DEPLOY_DATA_PCT=0`.

---

## 2. `nomade-diag`

Objectif : sur un PC quelconque, en une commande, rapporter de quoi comparer ce PC et cette clé à
d'autres. Purement informatif : rien n'est modifié sur le PC (D-042), et sur la clé seuls l'archive
et, en option, un fichier d'essai délié sont écrits.

### 2.1 Usage

```
nomade-diag                # ≈ 30 s, anonymisé, sans mesures
nomade-diag --mesures      # + lectures directes (≈ 25 s), écritures plafonnées (≤ 1 Gio, ≈ 30 s), AES
nomade-diag --brut         # sans anonymisation, pour soi (archive suffixée -brut, refusée par diag-rapport)
nomade-diag --sortie DIR   # ailleurs que sur NOMADE-DATA
nomade-diag --test         # pour l'autotest : ni sudo ni session graphique, sortie dans /run
```

Lancé depuis un terminal de la session : la partie **session** (rendu OpenGL, type de session, son)
tourne sous l'utilisateur, puis le script se relance par `sudo` pour la partie **système** (sysfs
réservé, `dmidecode`, journal complet, lectures directes), en lui passant le dossier de la première
partie. Chaque section est indépendante, bornée par `timeout` (10 s) et notée « non lu » en cas
d'échec : le diagnostic n'avorte jamais. Il affiche à la fin un résumé lisible et le chemin de l'archive.

Sur la clé de 1 To, qui ne sera pas redéployée, le script se lance **depuis le clone du dépôt**
(`sudo python3 -I config/rootfs/usr/local/lib/nomade/nomade-diag.py`) : il ne dépend d'aucun fichier
de l'image hormis sa table, qu'il cherche aussi à côté de lui.

### 2.2 Ce qui est relevé

| Domaine | Contenu | Sources |
|---|---|---|
| Versions | `NOMADE_VERSION`, image, `DEPLOY_VERSION`, Zorin, noyau, shim, GRUB, Mesa ; **autotest sur matériel réel** | `/etc/nomade/*-info`, `os-release`, `dpkg-query` ; `selftest.sh` en mode « matériel » (voir 2.6) |
| PC | fabricant, modèle, famille, carte mère ; firmware (éditeur, version, date) ; processeur ; RAM (taille, type, vitesse, barrettes) ; batterie (usure, sans numéro) ; TPM présent | `/sys/class/dmi/id`, `lscpu`, `dmidecode -t 17`, `/sys/class/power_supply` |
| Démarrage sécurisé | état (`mokutil --sb-state`), mode installation, **« Microsoft Corporation UEFI CA 2011 » et « Microsoft UEFI CA 2023 » dans db**, éditeur du PK, nombre d'entrées dbx, révocations SBAT | `mokutil --db / --pk / --list-sbat-revocations`, efivars (lecture seule) |
| Affichage | GPU (PCI, pilote), **moteur de rendu, et repli logiciel `llvmpipe` signalé**, session Wayland/X11, écrans (connecteur, fabricant et modèle EDID, définition) | `lspci -nnk`, `glxinfo -B` (session), `/sys/class/drm` |
| Autres périphériques | réseau (type, puce, pilote, firmware chargé, Wi-Fi fonctionnel ou non), son (cartes), Bluetooth, webcam | `lspci`, `lsusb`, `nmcli -t -f TYPE,STATE device`, `pactl info` (session) |
| Clé et pont | VID:PID et **identification par la table Fabrique-Clé**, noms `usb.ids` (hwdb), norme et liaison négociée, bridée en USB 2, à travers un concentrateur, pilote, file de commandes, TRIM (`discard_max_bytes`, `provisioning_mode`), rotatif déclaré, ordonnanceur, quirks ; capacité et partitions ; drapeaux LUKS ; dernier `fstrim` ; **réinitialisations USB** (`uas_eh`, `reset SuperSpeed`) et erreurs d'E/S | sysfs (parcours de `disques/linux.rs::identifier`), `systemd-hwdb`, `lsusb -t`, `lsblk -b`, `cryptsetup status`, journal |
| Démarrage | firmware, chargeur, noyau + initramfs (**saisie de la phrase comprise** : l'initramfs ne la journalise pas), espace utilisateur, 15 unités les plus lentes, chaîne critique | `systemd-analyze time / blame / critical-chain` |
| Mémoire | totale, disponible, zram (taille, taux de compression), swap utilisé, pression (PSI), plus gros consommateurs (noms de programmes) | `/proc/meminfo`, `zramctl`, `/proc/pressure`, `ps` |
| Écritures | écrit depuis le démarrage (disque et volume chiffré), débit moyen par heure, total ext4 depuis la création | `/proc/diskstats`, `/sys/fs/ext4/*/lifetime_write_kbytes`, `uptime` |
| Erreurs | unités en échec, nombre d'erreurs du journal par unité, firmwares manquants, erreurs ACPI, noyau contaminé, Oops/WARN, blocages GPU, plantages (noms de programmes) | `systemctl --failed`, `journalctl -b -p err`, `journalctl -k -b`, `coredumpctl list` |

Toujours pour le démarrage en cours seulement. En option plus tard (`--historique`) : un résumé des
démarrages précédents gardés par le journal (la ligne noyau `DMI: …` donne le PC de chacun).

### 2.3 Mesures (`--mesures`, en option et plafonnées)

Même protocole que l'onglet Diagnostic de Fabrique-Clé (`diagnostic/mesures.rs`, `analyse.rs`), pour
que les chiffres des deux outils se comparent :

- **lecture** directe (`O_DIRECT`, tampons alignés sur 4096) sur le disque entier, sans rien écrire :
  séquentielle par 4 Mio (8 s), aléatoire 4 Kio une à la fois (8 s), puis 8 à la fois (8 s, un
  descripteur par fil) ; médiane, 90 %, 99 %, maximum, histogramme aux mêmes classes (100 µs … 50 ms) ;
- **écriture** sur un fichier d'essai délié dès son ouverture (disparu même après un arrêt brutal),
  dans l'espace libre de la **racine** (le chemin réel du système : ext4 sur LUKS), zone de 256 Mio :
  4 Kio aléatoires (1 puis 8), écritures synchronisées (`fdatasync` à chaque bloc), puis écriture
  séquentielle longue ; **plafond de 1 Gio écrit au total** et 30 s pour la partie longue
  (`--ecriture-max 0` : pas d'écriture) ; refus si la racine a moins de 2 Gio libres ;
- **chiffrement** : `cryptsetup benchmark -c aes-xts-plain64 -s 512` (≈ 2 s).

Sans l'analyse complète de Fabrique-Clé (qui efface la clé) : pas de contrôle de capacité réelle.
Python ajoute quelques microsecondes par opération, peu devant les ≈ 200 µs de médiane mesurés sur la
clé de 1 To ; un **étalonnage** est prévu : mêmes mesures par Fabrique-Clé et par `nomade-diag` sur la
même clé, écart consigné.

### 2.4 Anonymisation (par défaut)

Principe : **liste blanche** pour `resume.json`, **nettoyage** pour les fichiers bruts, et rien de
personnel n'est seulement collecté.

- **Jamais collecté** : connexions et journaux de NetworkManager, wpa_supplicant, avahi, journal de la
  session utilisateur, historique, contenu de `/home`, noms de réseaux, liste des processus avec
  arguments. Pour les unités réseau, le journal ne donne que des **nombres** d'erreurs.
- **Remplacé par une empreinte** : numéros de série DMI (produit, carte, châssis), UUID du système,
  numéros de série USB (clé et autres périphériques), du disque, des écrans (EDID), `machine-id`,
  `boot_id`, UUID des systèmes de fichiers et du volume LUKS. Le script relève d'abord ces valeurs
  dans sysfs, puis les remplace **à l'identique** partout (journal compris) par
  `«empreinte:pc:3f9c…»`. Empreinte = HMAC-SHA-256 tronqué à 16 caractères hexadécimaux, avec un **sel
  propre à la clé**, tiré au premier lancement dans `/var/lib/nomade/diag-sel` (racine chiffrée,
  root seul). Le même PC diagnostiqué deux fois avec la même clé donne la même empreinte (les
  doublons se reconnaissent) ; un numéro de série ne se retrouve pas par force brute sans le sel, et
  deux clés ne permettent pas de recouper leurs PC entre eux.
- **Effacé par motif** : adresses MAC et Bluetooth, IPv4 et IPv6 (hors `127.*`, `::1`), courriels,
  nom de l'utilisateur et `/home/<nom>` (→ `utilisateur`), nom de machine s'il n'est pas `zorin-nomade`.
- **Contrôle avant d'écrire l'archive** : recherche de chaque valeur sensible relevée et des motifs
  MAC/IP dans tout ce qui part ; une seule trouvaille → l'archive n'est pas écrite (erreur).
- `--brut` désactive tout cela, l'annonce, et `make diag-rapport` refuse une archive marquée
  `"anonymise": false`.

### 2.5 Archive et `resume.json`

```
nomade-diag-20261108-1700-hp-probook-455-g10.tar.zst      (< 5 Mo)
├── resume.json      faits retenus, schéma versionné (liste blanche)
├── rapport.txt      lecture humaine en français : faits, alertes (« pas de Microsoft UEFI CA 2011 :
│                    activer l'option du firmware pour Secure Boot », « rendu logiciel », « USB 2 »…)
├── brut/*.txt       sorties des commandes, nettoyées
└── journal/         noyau et erreurs système du démarrage en cours, nettoyés
```

`<modèle>` : `product_name` DMI réduit en minuscules ASCII (40 caractères au plus). Destination :
`/media/NOMADE-DATA/nomade-diag/` si la partition est montée, sinon `~/nomade-diag/`.

**Stabilité du schéma** : champ `schema` entier ; dans un même numéro, on **ajoute** des champs, on
n'en renomme ni n'en retire aucun, on n'en change pas le sens ni l'unité ; `null` = non relevé ; unité
dans le nom (`_s`, `_mib`, `_mbps`, `_us`). Toute rupture incrémente `schema`, et `make diag-rapport`
lit tous les numéros connus. Ébauche du schéma 1, remplie avec ce que le journal donne de la clé de
1 To sur le HP (« … » ou `null` pour ce qu'il ne dit pas) :

```json
{
  "schema": 1,
  "outil": { "nom": "nomade-diag", "version": "0.2.0-alpha" },
  "date": "2026-11-08T12:00:00+01:00",
  "anonymise": true,
  "options": { "mesures": true, "ecriture_max_mib": 1024 },
  "systeme": { "nomade_version": "…", "image": "…",
               "deploy_version": "…", "zorin": "18.1", "noyau": "7.0.0-…",
               "autotest": { "pass": null, "fail": null, "echecs": [] } },
  "pc": { "empreinte": "3f9c…", "fabricant": "HP", "modele": "HP ProBook 455 G10", "famille": "…",
          "firmware": { "editeur": "…", "version": "…", "date": "…" },
          "cpu": "AMD Ryzen 3 7330U", "ram_mib": 7168, "ram": { "type": null, "vitesse_mts": null },
          "secure_boot": { "actif": false, "mode_installation": null, "ms_uefi_ca_2011": false,
                           "ms_uefi_ca_2023": null, "pk": "…", "dbx_entrees": null },
          "gpu": [ { "pci": "1002:…", "nom": "…", "pilote": "…" } ],
          "rendu": { "session": "…", "moteur": "…", "logiciel": null },
          "reseau": [ { "type": "wifi", "id": "…", "pilote": "…", "fonctionne": null } ] },
  "cle": { "empreinte": "a17e…", "vid_pid": "090c:2320",
           "identification": { "role": "ssd", "nom": "Silicon Motion SM2320, …" },
           "usb": { "version": null, "vitesse_mbps": 10000, "pilote": "uas",
                    "bridee_usb2": false, "concentrateur": null },
           "capacite_gio": 931.5, "trim": true, "provisioning_mode": "unmap", "file_commandes": null,
           "rotatif_declare": false, "ordonnanceur": "mq-deadline",
           "reinitialisations_usb": 0, "erreurs_es": null, "data_gib": 0 },
  "demarrage": { "firmware_s": 16.3, "chargeur_s": 7.3, "noyau_s": 15.4, "espace_utilisateur_s": 10.6,
                 "plus_lents": [ { "unite": "…", "s": null } ] },
  "memoire": { "totale_mib": 7168, "disponible_mib": null, "zram_mib": 3584, "zram_taux": null,
               "swap_utilise_mib": null, "psi_memoire_avg300": null },
  "ecritures": { "depuis_demarrage_mib": null, "uptime_s": null, "ext4_total_gib": null },
  "erreurs": { "unites_en_echec": [], "journal_err": null, "firmwares_manquants": [],
               "acpi": null, "oops": null, "gpu_blocages": null, "plantages": [] },
  "mesures": { "directes": true, "lecture_seq_mo_s": 815,
               "lecture_4k_qd1": { "iops": 4900, "mediane_us": 200, "p99_us": 280 },
               "lecture_4k_qd8": { "iops": null, "mediane_us": null, "p99_us": null },
               "ecriture_4k_qd1_mo_s": null, "ecriture_sync_mediane_us": 1000,
               "ecriture_seq_mo_s": 560, "aes_xts_mio_s": 1740 }
}
```

Le schéma définitif sera documenté pour les utilisateurs dans `docs/diagnostic.md` (avec la marche à
suivre), et `make diag-rapport` le valide.

### 2.6 Autotest et essais

- **Autotest sur matériel réel** : `selftest.sh` gagne un mode `--materiel` (sans `fw_cfg`, sans port
  série ni extinction, Secure Boot attendu = état lu) ; `nomade-diag` l'appelle et reporte les
  `PASS`/`FAIL` dans `resume.json`. C'est la ligne « versions et autotest » de `PLAN.md`.
- **E-45** dans l'autotest QEMU : `nomade-diag --test` produit une archive lisible, `resume.json`
  valide (schéma 1), et **aucune valeur sensible connue** n'y figure : `test-image.sh` donne au disque
  simulé un numéro de série repère (`usb-storage,…,serial=NOMADETEST0001`) ; l'autotest vérifie qu'on
  ne le retrouve nulle part dans l'archive, pas plus que le `machine-id`, l'adresse MAC de la carte
  réseau de QEMU ou le nom de l'utilisateur, mais que son empreinte, elle, y est.
- `make deploy-test` : l'archive s'écrit sur `NOMADE-DATA`.
- Sur l'hôte : `python3 -I -m py_compile` et tests unitaires (`unittest`, sans dépendance) de
  l'anonymisation, de la lecture de la table et des centiles, dans `make lint` / `make ci`.

---

## 3. Côté hôte : `make diag-rapport`

```
diagnostics/
├── archives/     *.tar.zst copiées depuis NOMADE-DATA (ignoré par git : journaux bruts)
└── resumes/      <date>-<modèle>-<empreinte clé>.json  (versionné)
docs/terrain.md   tableau comparatif, généré (« ne pas modifier à la main »), versionné
```

`make diag-rapport [SRC=/media/fabien/NOMADE-DATA/nomade-diag]` (`scripts/diag-rapport.py`,
`python3 -I`) : copie les nouvelles archives de `SRC` dans `diagnostics/archives/`, en extrait
`resume.json` (`tar --zstd -xOf`), refuse les archives non anonymisées et refait le contrôle des motifs
MAC/IP, range le résumé dans `diagnostics/resumes/`, puis régénère `docs/terrain.md` :

- **PC** : modèle, firmware, Secure Boot et présence des CA Microsoft, GPU et pilote, rendu logiciel,
  Wi-Fi, temps de démarrage, erreurs notables ;
- **clés** : puce et rôle, pilote, liaison, TRIM, réinitialisations, mesures, catégorie A–D estimée
  avec les seuils de Fabrique-Clé (`interpretation.rs::estimation`, à partir de l'écriture 4 Kio) ;
- **couples PC × clé** : un même PC diagnostiqué deux fois avec la même clé (mêmes empreintes) ne
  garde que le diagnostic le plus récent.

Versionner les résumés : le dépôt est **public**. `resume.json` étant construit sur liste blanche et
contrôlé deux fois, son contenu (modèles de PC et de clés, versions, mesures) ne dit rien des
personnes ; il donne l'historique et rend `docs/terrain.md` reproductible. Les archives complètes,
plus bavardes, restent hors du dépôt.

---

## 4. Réutiliser le code Rust de Fabrique-Clé ou réécrire ?

Ce que couvre l'onglet Diagnostic (`reference/debian/app/src/diagnostic/`, ≈ 2 900 lignes) : la
**clé seule** — identification (sysfs, table, `usb.ids`), mesures en lecture, analyse en écriture,
fiches et catégories. Rien sur le PC, le firmware, le démarrage, la mémoire ni les erreurs, soit les
deux tiers de `nomade-diag`.

| | Rust (réutiliser) | Bash (+ `fio`, `jq`) | **Python 3 (réécrire)** |
|---|---|---|---|
| Part reprise | module `diagnostic/`, mais lié à `crate::disques`, `crate::suivi`, `crate::assistant` (pkexec) : il faudrait en tirer une crate commune, donc modifier Fabrique-Clé, projet à part | la table seulement | la table, le parcours sysfs et le protocole, transposés |
| Reste à écrire | PC, firmware, démarrage, journal, archive, anonymisation (en Rust ou dans un second langage) | tout | tout, dans un seul langage, partagé avec `diag-rapport` |
| Chaîne de construction | édition 2024 → Rust ≥ 1.85 ; Noble fournit 1.75 par défaut : rustup ou paquet versionné dans la VM de build, crates à télécharger et à mettre en cache, compilation à chaque modification | rien, mais `fio` à ajouter à l'image | rien : `python3` 3.12 est déjà dans l'image, bibliothèque standard suffisante (`json`, `hmac`, `os.preadv`, `mmap`) |
| Retouche sur la clé | impossible sans `cargo` | oui | **oui** : Claude Code lancé sur la clé modifie et relance le script sur place, sur le PC concerné |
| Mesures | les meilleures | `fio` : latences et JSON, mais protocole différent de Fabrique-Clé | transposition fidèle du protocole ; surcoût de quelques µs par opération, à étalonner |
| JSON, empreintes, anonymisation | bon | laborieux (`jq`, `sed`, HMAC par `openssl`) | naturel |

**Recommandation : réécrire en Python 3**, un seul fichier (`config/rootfs/usr/local/lib/nomade/
nomade-diag.py`, lanceur `/usr/local/bin/nomade-diag`), lancé par `python3 -I`, sans dépendance hors
bibliothèque standard. On reprend de Fabrique-Clé, sans son code :
- `fabricants-usb.txt` **copiée telle quelle** (même format, en-tête de provenance et date de copie)
  dans `config/rootfs/usr/share/nomade/` ; une clé rencontrée sur le terrain enrichit les deux copies ;
- le parcours sysfs d'`identifier` (de `block` jusqu'à l'interface USB puis au périphérique) ;
- le protocole de mesure (durées, tailles de blocs, 8 en parallèle, classes de l'histogramme) ;
- les seuils de catégorie A–D, côté `diag-rapport`.

`usb.ids.zst` n'est pas repris : l'image a déjà la base hwdb de systemd (`systemd-hwdb query
usb:v090Cp2320`).

Déviation à consigner : `CLAUDE.md` autorise Python « pour l'outillage de test ». `nomade-diag` est
un outil embarqué dans le système livré : décision à prendre (D-047) et phrase de `CLAUDE.md` à
élargir (« outillage de test et de diagnostic »). Si l'interface Rust de « plus tard » voit le jour,
elle lira `resume.json` plutôt que de refaire la collecte.

---

## 5. Étapes proposées (un commit, ou plus, par étape)

1. **`NOMADE-DATA`** : paramètres, `data_gib` + essais `make ci`, `deploy.sh` (taille, `fstab`),
   `exfatprogs` dans l'image, autotest E-44, SPEC (E-29, E-44), D-046, README, CHANGELOG ;
   `make all` puis `make deploy-test RUNS=2`.
2. **`nomade-diag`, collecte et anonymisation** (sans mesures) : script, table, `selftest.sh --materiel`,
   numéro de série repère dans `test-image.sh`, autotest E-45, `docs/diagnostic.md`, D-047, D-048 ;
   `make test`, `make deploy-test`.
3. **Mesures** (`--mesures`), plafonds, tests unitaires des centiles.
4. **`make diag-rapport`**, `diagnostics/`, `.gitignore`, `docs/terrain.md` vide, D-049.
5. **Essais réels (Fabien)** : la clé de 1 To depuis le clone, la clé de 128 Go redéployée en 0.2
   (`NOMADE-DATA` de 11 Gio), puis quelques PC ; étalonnage contre Fabrique-Clé ; premier
   `docs/terrain.md`.

GNOME Logiciels sans service résident (dernière ligne de la 0.2 dans `PLAN.md`) reste un chantier
séparé, indépendant de cette note.

## 6. Questions pour Fabien

1. **Plancher de 8 Gio** et seuil « racine ≥ `IMAGE_ROOT_GIB` + 16 Gio » : d'accord ?
2. **Point de montage** `/media/NOMADE-DATA` (chemin fixe, montage par `fstab`), ou préfères-tu la voie
   udisks (`/media/fabien/NOMADE-DATA`, montée au clic) ?
3. **Sel des empreintes propre à chaque clé** (deux clés sur le même PC donnent deux empreintes
   différentes) ou commun à tes clés (sel fourni au déploiement, recoupement possible) ?
4. **`diagnostics/resumes/` versionné** dans le dépôt public : d'accord, ou dépôt séparé / non versionné ?
5. Un **lanceur dans le menu** (« Diagnostic de la clé », qui ouvre un terminal), pour qu'un élève le
   lance sans taper de commande ? Ou le terminal seulement, pour l'instant ?
6. **Mesures d'écriture** sur la racine (chemin réel, chiffré) avec un plafond de 1 Gio : d'accord ?
   (Autre choix : sur `NOMADE-DATA`, la clé sans chiffrement, mais pas là où le système écrit.)
7. **Python pour un outil embarqué** (déviation à la consigne de `CLAUDE.md`) : d'accord ?
