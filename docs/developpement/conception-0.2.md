# Conception 0.2 — `NOMADE-DATA` par défaut, diagnostics de la clé et du système, rapport de terrain

Statut : **proposition, à valider par Fabien** (2026-11-08, révisée le même jour : deux diagnostics
distincts). Rien n'est codé. Une fois validée, les choix passent dans `DECISIONS.md` (D-046 et
suivantes), `SPEC.md` (E-29 modifiée ; E-44 `NOMADE-DATA`, E-45 `diag-cle`, E-46 `nomade-diag`) et
`PLAN.md` ; cette note reste comme trace de la conception.

Deux diagnostics, deux moments :

| | **Avant le déploiement** : `make diag-cle` | **Après le déploiement** : `nomade-diag` |
|---|---|---|
| Lancé depuis | la machine hôte, le dépôt cloné | le système déployé sur la clé |
| Question posée | que vaut cette clé ? faut-il y déployer ? | comment se comporte le système sur ce PC ? |
| Objet | la clé seule, à fond | le PC, le démarrage, la mémoire, les erreurs, et la clé telle qu'elle se comporte sur ce PC |
| Écriture | aucune par défaut ; analyse complète **qui efface la clé** sur demande (`COMPLET=1`) | l'archive, et en option un fichier d'essai plafonné |
| Rapport | `diagnostics/` du dépôt | `NOMADE-DATA` (sinon `~/nomade-diag/`) |

Les deux produisent une archive avec un `resume.json` au schéma stable ; `make diag-rapport` les
rassemble dans `docs/terrain.md`, reliés par l'empreinte de la clé.

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
| `diag-cle` | outil séparé de `deploy` ; **lecture seule par défaut** (identification sans root, lectures directes avec `sudo`) ; **analyse complète sur demande** (`COMPLET=1`, efface la clé, mêmes garde-fous que `deploy`) |
| `nomade-diag` | sur la clé : partie session en utilisateur, partie système par `sudo` |
| Langage | **Python 3 (bibliothèque standard seule)**, un module commun aux deux outils ; on reprend de Fabrique-Clé la table des puces, le parcours sysfs et le protocole de mesure, pas le code Rust |
| Anonymisation | par défaut : `resume.json` sur liste blanche, fichiers bruts nettoyés, numéros de série remplacés par des empreintes salées |
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

## 2. Avant le déploiement : `make diag-cle` (sur l'hôte)

Objectif : savoir ce que vaut une clé **avant** d'y installer le système. Ce qu'elle est, ce qu'elle
tient en lecture, et, sur demande, en écriture, contrefaçon comprise ; puis un verdict : déployer ou
non, et à quoi s'attendre. Outil **séparé** de `deploy` (choix de Fabien). C'est l'équivalent, en
ligne de commande, de l'onglet Diagnostic de Fabrique-Clé.

### 2.1 Usage

```
make diag-cle KEY=/dev/disk/by-id/usb-…              # identification seule, sans root (≈ 2 s)
sudo make diag-cle KEY=/dev/disk/by-id/usb-…         # par défaut avec root : + lectures directes (≈ 30 s),
                                                     # rien n'est écrit sur la clé
sudo make diag-cle KEY=… COMPLET=1 [DUREE=3]         # analyse complète : EFFACE la clé (5 à 15 min)
```

`scripts/diag-cle.sh` (Bash : `load_env`, gardes de `lib.sh`, puis `python3 -I` du module commun,
voir 4.1). Sans root, les lectures directes du disque sont impossibles : le rapport s'en tient à
l'identification et le dit. La clé peut être une clé neuve, une clé quelconque ou une clé nomade déjà
déployée (la lecture seule ne la change pas).

### 2.2 Garde-fous (règle 5 de `CLAUDE.md`)

- **Lecture seule** : nouvelle fonction `assert_usb_disk` dans `lib.sh`, mêmes contrôles
  qu'`assert_real_usb_target` (chemin `by-id/usb-*`, disque entier, transport USB, aucun système de
  fichiers de l'hôte) **sans** la saisie du numéro de série, puisque rien n'est écrit ; une clé montée
  est acceptée. Le disque n'est ouvert qu'en `O_RDONLY | O_DIRECT`.
- **Analyse complète** : `assert_real_usb_target` **inchangée** (clé démontée, numéro de série tapé),
  exactement comme `deploy`, et règle udev temporaire `UDISKS_IGNORE` comme dans `deploy.sh`.
- **Essais par Claude** : uniquement dans la VM de build, sur fichier ou loop (`assert_test_target`,
  `DEPLOY_TEST=1`) : `make diag-cle-test` (2.7). Jamais sur un vrai périphérique (règle 1).
- `scripts/test-guards.sh` gagne les refus attendus d'`assert_usb_disk` (partition, disque non USB,
  disque de l'hôte).

### 2.3 Identification (sans root)

- Parcours sysfs de Fabrique-Clé (`disques/linux.rs::identifier`) : VID:PID, **table
  `fabricants-usb.txt`** (rôle : marque, contrôleur, pont, SSD natif, suspect), noms hwdb, chaînes du
  descripteur USB ;
- norme annoncée (`bcdUSB`) et **liaison négociée** → alerte si bridée en USB 2 (port, câble,
  rallonge), concentrateur intermédiaire (`lsusb -t`) ;
- pilote `uas` / `usb-storage`, quirks du noyau pour ce VID:PID, file de commandes ;
- TRIM **déclaré** (`discard_max_bytes`), secteurs logique et physique, transfert maximal, rotatif
  déclaré, capacité annoncée ;
- table de partitions actuelle (clé nomade reconnue à ses noms GPT `nomade-root` / `NOMADE-DATA`).
- **SMART**, si `smartctl` est installé sur l'hôte (facultatif, absent aujourd'hui) : `-d sat` pour
  un SSD SATA derrière un pont (le VL715), `-d sntjmicron|sntasmedia|sntrealtek` pour les ponts NVMe
  connus de la table. Santé, heures de fonctionnement, **volume déjà écrit**, réserve : l'usure d'une
  clé d'occasion. Pont qui ne relaie rien : « non lu ».

### 2.4 Lecture seule (par défaut, avec root)

Protocole de `diagnostic/mesures.rs`, à l'identique : lectures directes (`O_DIRECT`, tampons alignés
sur 4096) **bornées en durée** : séquentielle par 4 Mio (8 s), aléatoire 4 Kio une à la fois (8 s),
puis 8 à la fois (8 s, un descripteur par fil) ; médiane, 90 %, 99 %, maximum, histogramme aux mêmes
classes (100 µs … 50 ms) ; part des blocs entièrement nuls. Le gain de 8 lectures parallèles sur une
seule est un bon indice d'un contrôleur de type SSD. Rien n'est écrit.

### 2.5 Analyse complète (`COMPLET=1`, efface la clé)

Protocole de `diagnostic/analyse.rs`, plus un essai de TRIM réel :

1. **capacité réelle** : marqueurs écrits sur une grille au pas puissance de deux, puis relus ; un
   repliement d'adresses (contrefaçon) écrase un marqueur déjà écrit ;
2. **essai de TRIM réel** (`blkdiscard -f` d'une zone, puis relecture) : annonce ce que `deploy` fera
   (`DEPLOY_DISCARD`, `provisioning_mode`) ;
3. écriture aléatoire 4 Kio, 1 puis 8 à la fois ;
4. écritures synchronisées (`fdatasync` à chaque bloc) : ce que vivent dpkg et les navigateurs ;
5. **longue écriture séquentielle** (`DUREE` minutes, 3 par défaut, comme les choix 1 / 3 / 10 de
   Fabrique-Clé ; arrêt en fin de clé), courbe du débit, **chute du cache SLC** repérée ;
6. lecture aléatoire sur les données écrites ;
7. remise à vide : `blkdiscard` de toute la clé si le TRIM passe, sinon premier et dernier Mio remis
   à zéro. La clé ressort sans table de partitions, prête pour `deploy`.

Volume écrit : jusqu'à `DUREE` × débit (≈ 90 Go en 3 min à 500 Mo/s), sans importance pour un SSD
(endurance de centaines de To), à ne pas répéter inutilement sur une clé ordinaire.

### 2.6 Verdict, rapport et lien avec `deploy`

- **Verdict** en français : catégorie A à D avec les seuils de Fabrique-Clé
  (`interpretation.rs::estimation` : écriture 4 Kio < 0,1 Mo/s → A, < 2 → B, < 10 → entre B et C,
  < 30 → C, au-delà → D), **estimée** en lecture seule à partir des indices (pont ou SSD natif connu,
  UAS, TRIM, gain du parallélisme), **mesurée** après l'analyse complète.
- **Alertes** : « capacité réelle inférieure à l'annonce : ne pas déployer » ; « liaison en USB 2 :
  change de port ou de câble » ; « `usb-storage`, sans TRIM : fonctionnera, sans file de commandes ni
  TRIM » ; « rotatif déclaré : corrigé par la règle udev au déploiement ».
- **Rapport** dans `diagnostics/archives/` et `diagnostics/resumes/` du dépôt (format en 4.4), rendu
  à l'utilisateur (`SUDO_UID`) et non laissé à root.
- **Lien avec `deploy`**, sans les fusionner : `deploy.sh` affiche le verdict du dernier `diag-cle`
  de la même clé (même empreinte), ou suggère d'en lancer un ; il inscrit l'empreinte de la clé dans
  `deploy-info` (`DEPLOY_CLE_EMPREINTE`), que `nomade-diag` reprend (4.2).

### 2.7 Essais (`make diag-cle-test`, VM de build)

- lecture seule sur un loop adossé à un fichier creux : SHA-256 du fichier **identique** avant et
  après (rien n'a été écrit) ;
- analyse complète sur un fichier sain : capacité conforme, clé vide à la fin ;
- analyse complète sur une **contrefaçon simulée** : table device-mapper `linear` qui annonce 8 Gio
  mais replie la seconde moitié sur la première ; repliement détecté, verdict « ne pas déployer » ;
- les chiffres mesurés dans la VM n'ont pas de sens : on vérifie le déroulement et le résumé.

---

## 3. Après le déploiement : `nomade-diag` (sur la clé)

Objectif : sur un PC quelconque, en une commande, rapporter de quoi comparer ce PC, et la clé sur ce
PC, à d'autres. Purement informatif : rien n'est modifié sur le PC (D-042), et sur la clé seuls
l'archive et, en option, un fichier d'essai délié sont écrits. La caractérisation poussée de la clé
(capacité, écriture longue, SMART) relève de `diag-cle` ; ici ne compte que ce qui change d'un PC à
l'autre.

### 3.1 Usage

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

### 3.2 Ce qui est relevé

| Domaine | Contenu | Sources |
|---|---|---|
| Versions | `NOMADE_VERSION`, image, `DEPLOY_VERSION`, Zorin, noyau, shim, GRUB, Mesa ; **autotest sur matériel réel** | `/etc/nomade/*-info`, `os-release`, `dpkg-query` ; `selftest.sh` en mode « matériel » (3.4) |
| PC | fabricant, modèle, famille, carte mère ; firmware (éditeur, version, date) ; processeur ; RAM (taille, type, vitesse, barrettes) ; batterie (usure, sans numéro) ; TPM présent | `/sys/class/dmi/id`, `lscpu`, `dmidecode -t 17`, `/sys/class/power_supply` |
| Démarrage sécurisé | état (`mokutil --sb-state`), mode installation, **« Microsoft Corporation UEFI CA 2011 » et « Microsoft UEFI CA 2023 » dans db**, éditeur du PK, nombre d'entrées dbx, révocations SBAT | `mokutil --db / --pk / --list-sbat-revocations`, efivars (lecture seule) |
| Affichage | GPU (PCI, pilote), **moteur de rendu, et repli logiciel `llvmpipe` signalé**, session Wayland/X11, écrans (connecteur, fabricant et modèle EDID, définition) | `lspci -nnk`, `glxinfo -B` (session), `/sys/class/drm` |
| Autres périphériques | réseau (type, puce, pilote, firmware chargé, Wi-Fi fonctionnel ou non), son (cartes), Bluetooth, webcam | `lspci`, `lsusb`, `nmcli -t -f TYPE,STATE device`, `pactl info` (session) |
| La clé sur ce PC | VID:PID et identification (table), **liaison négociée sur ce port**, bridée en USB 2, concentrateur, pilote, TRIM effectif (`provisioning_mode`), réglages udev appliqués ; drapeaux LUKS ; dernier `fstrim` ; **réinitialisations USB** (`uas_eh`, `reset SuperSpeed`) et erreurs d'E/S | sysfs (même parcours que `diag-cle`), `lsusb -t`, `cryptsetup status`, journal |
| Démarrage | firmware, chargeur, noyau + initramfs (**saisie de la phrase comprise** : l'initramfs ne la journalise pas), espace utilisateur, 15 unités les plus lentes, chaîne critique | `systemd-analyze time / blame / critical-chain` |
| Mémoire | totale, disponible, zram (taille, taux de compression), swap utilisé, pression (PSI), plus gros consommateurs (noms de programmes) | `/proc/meminfo`, `zramctl`, `/proc/pressure`, `ps` |
| Écritures | écrit depuis le démarrage (disque et volume chiffré), débit moyen par heure, total ext4 depuis la création | `/proc/diskstats`, `/sys/fs/ext4/*/lifetime_write_kbytes`, `uptime` |
| Erreurs | unités en échec, nombre d'erreurs du journal par unité, firmwares manquants, erreurs ACPI, noyau contaminé, Oops/WARN, blocages GPU, plantages (noms de programmes) | `systemctl --failed`, `journalctl -b -p err`, `journalctl -k -b`, `coredumpctl list` |

Toujours pour le démarrage en cours seulement. En option plus tard (`--historique`) : un résumé des
démarrages précédents gardés par le journal (la ligne noyau `DMI: …` donne le PC de chacun).

### 3.3 Mesures (`--mesures`, en option et plafonnées)

- **lecture** : le protocole de `diag-cle` (2.4), à l'identique, sur le disque entier : comparer
  d'un PC à l'autre l'effet du port et du contrôleur USB, et avec la mesure faite depuis l'hôte ;
- **écriture** sur un fichier d'essai délié dès son ouverture (disparu même après un arrêt brutal),
  dans l'espace libre de la **racine** (le chemin réel du système : ext4 sur LUKS), zone de 256 Mio :
  4 Kio aléatoires (1 puis 8), écritures synchronisées, puis écriture séquentielle ; **plafond de
  1 Gio écrit au total** et 30 s pour la partie longue (`--ecriture-max 0` : pas d'écriture) ; refus
  si la racine a moins de 2 Gio libres ;
- **chiffrement** : `cryptsetup benchmark -c aes-xts-plain64 -s 512` (≈ 2 s).

### 3.4 Autotest et essais

- **Autotest sur matériel réel** : `selftest.sh` gagne un mode `--materiel` (sans `fw_cfg`, sans port
  série ni extinction, Secure Boot attendu = état lu) ; `nomade-diag` l'appelle et reporte les
  `PASS`/`FAIL` dans `resume.json`. C'est la ligne « versions et autotest » de `PLAN.md`.
- **E-46** dans l'autotest QEMU : `nomade-diag --test` produit une archive lisible, `resume.json`
  valide (schéma 1), et **aucune valeur sensible connue** n'y figure : `test-image.sh` donne au disque
  simulé un numéro de série repère (`usb-storage,…,serial=NOMADETEST0001`) ; l'autotest vérifie qu'on
  ne le retrouve nulle part dans l'archive, pas plus que le `machine-id`, l'adresse MAC de la carte
  réseau de QEMU ou le nom de l'utilisateur, mais que son empreinte, elle, y est.
- `make deploy-test` : l'archive s'écrit sur `NOMADE-DATA`, et `DEPLOY_CLE_EMPREINTE` est reprise.

---

## 4. Commun aux deux outils

### 4.1 Un module Python partagé

`config/rootfs/usr/local/lib/nomade/nomade_diag/` (`materiel.py` : parcours sysfs et table ;
`mesures.py` : protocole de lecture et d'écriture ; `anonymat.py` ; `archive.py` : `resume.json`,
`rapport.txt`, `tar.zst`). Il part dans l'image pour `nomade-diag` ; `scripts/diag-cle.sh` l'importe
depuis le dépôt. Même code, mêmes mesures des deux côtés. Tests unitaires sur l'hôte (`unittest`,
sans dépendance) : anonymisation, lecture de la table, centiles, règle de catégorie, dans
`make lint` / `make ci`.

### 4.2 Empreintes

Empreinte = HMAC-SHA-256 tronqué à 16 caractères hexadécimaux : reconnaître un même objet d'un
diagnostic à l'autre sans révéler son numéro de série, ni permettre de le retrouver par force brute
sans le sel.

- **Clé** : calculée par l'**hôte** (numéro de série USB et du disque), avec le sel de l'hôte
  `diagnostics/.sel` (tiré au premier `diag-cle`, ignoré par git). `deploy.sh` l'inscrit dans
  `deploy-info` (`DEPLOY_CLE_EMPREINTE`), et `nomade-diag` la reprend telle quelle : le diagnostic
  d'avant et ceux d'après portent la même empreinte. Clé déployée avant la 0.2 (la 1 To) : empreinte
  calculée sur la clé, non reliable à un `diag-cle`.
- **PC** (et périphériques) : calculée sur la clé, avec un sel propre à la clé tiré au premier
  lancement dans `/var/lib/nomade/diag-sel` (racine chiffrée, root seul). Variante (question 3) :
  `deploy.sh` copie le sel de l'hôte sur la clé, et un même PC garde la même empreinte d'une de tes
  clés à l'autre.

### 4.3 Anonymisation (par défaut)

Principe : **liste blanche** pour `resume.json`, **nettoyage** pour les fichiers bruts, et rien de
personnel n'est seulement collecté. `diag-cle` ne relève rien de l'hôte ni de ses fichiers ; ses seuls
identifiants sont ceux de la clé.

- **Jamais collecté** : connexions et journaux de NetworkManager, wpa_supplicant, avahi, journal de la
  session utilisateur, historique, contenu de `/home`, noms de réseaux, liste des processus avec
  arguments. Pour les unités réseau, le journal ne donne que des **nombres** d'erreurs.
- **Remplacé par une empreinte** : numéros de série DMI (produit, carte, châssis), UUID du système,
  numéros de série USB (clé et autres périphériques), du disque, des écrans (EDID), `machine-id`,
  `boot_id`, UUID des systèmes de fichiers et du volume LUKS. Le script relève d'abord ces valeurs
  dans sysfs, puis les remplace **à l'identique** partout (journal compris) par
  `«empreinte:pc:3f9c…»`.
- **Effacé par motif** : adresses MAC et Bluetooth, IPv4 et IPv6 (hors `127.*`, `::1`), courriels,
  nom de l'utilisateur et `/home/<nom>` (→ `utilisateur`), nom de machine s'il n'est pas `zorin-nomade`.
- **Contrôle avant d'écrire l'archive** : recherche de chaque valeur sensible relevée et des motifs
  MAC/IP dans tout ce qui part ; une seule trouvaille → l'archive n'est pas écrite (erreur).
- `--brut` (`nomade-diag`) ou `BRUT=1` (`diag-cle`) désactive tout cela, l'annonce, et
  `make diag-rapport` refuse une archive marquée `"anonymise": false`.

### 4.4 Archives et `resume.json`

```
diag-cle-20261108-1700-2109-0715-a17e….tar.zst            (diag-cle : date, VID-PID, empreinte)
nomade-diag-20261108-1700-hp-probook-455-g10.tar.zst      (nomade-diag : date, modèle du PC)
├── resume.json      faits retenus, schéma versionné (liste blanche)
├── rapport.txt      lecture humaine en français : faits, verdict, alertes
├── brut/*.txt       sorties des commandes, nettoyées
├── journal/         (nomade-diag) noyau et erreurs système du démarrage en cours, nettoyés
└── mesures/         latences et courbes détaillées, si mesurées
```

`<modèle>` : `product_name` DMI réduit en minuscules ASCII (40 caractères au plus). Archives de moins
de 5 Mo.

**Stabilité du schéma** : champs `schema` (entier) et `type` (`"cle"` ou `"systeme"`) ; dans un même
numéro, on **ajoute** des champs, on n'en renomme ni n'en retire aucun, on n'en change pas le sens ni
l'unité ; `null` = non relevé ; unité dans le nom (`_s`, `_mib`, `_mbps`, `_us`). Toute rupture
incrémente `schema`, et `make diag-rapport` lit tous les numéros connus. Le bloc `cle.usb` et les blocs
de mesure ont la même forme dans les deux types. Ébauches du schéma 1, remplies avec ce que le journal
donne (« … » ou `null` pour ce qu'il ne dit pas) :

`diag-cle` sur la clé de 128 Go (identification seule) :

```json
{
  "schema": 1, "type": "cle",
  "outil": { "nom": "diag-cle", "version": "0.2.0-alpha" },
  "date": "…", "anonymise": true,
  "options": { "mode": "identification", "duree_ecriture_min": null },
  "cle": { "empreinte": "…", "vid_pid": "2109:0715",
           "identification": { "role": "pont", "nom": "VIA Labs VL715 (probablement), …" },
           "usb": { "version": null, "vitesse_mbps": 10000, "pilote": "usb-storage",
                    "bridee_usb2": false, "concentrateur": null },
           "capacite_annoncee_gio": null, "trim_declare": null, "file_commandes": null,
           "rotatif_declare": true, "smart": null },
  "lecture": null,
  "analyse": null,
  "verdict": { "categorie": null, "certitude": "estimee", "alertes": [] }
}
```

Après `COMPLET=1`, `analyse` vaut par exemple `{ "capacite_reelle_conforme": true, "trim_reel": false,
"ecriture_4k_qd1_mo_s": …, "ecriture_4k_qd8_mo_s": …, "ecriture_sync_mediane_us": …,
"ecriture_seq_mo_s": …, "cache_slc_gio": … }` (le TRIM refusé par ce pont est connu par `deploy`).

`nomade-diag` sur la clé de 1 To et le HP :

```json
{
  "schema": 1, "type": "systeme",
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
suivre des deux outils), et `make diag-rapport` le valide.

---

## 5. Côté hôte : `make diag-rapport`

```
diagnostics/
├── .sel          sel des empreintes de clés (ignoré par git)
├── archives/     *.tar.zst : diag-cle directement, nomade-diag copiées depuis NOMADE-DATA (ignoré par git)
└── resumes/      <type>-<date>-<empreinte clé>-….json  (versionné)
docs/terrain.md   tableau comparatif, généré (« ne pas modifier à la main »), versionné
```

`make diag-rapport [SRC=/media/fabien/NOMADE-DATA/nomade-diag]` (`scripts/diag-rapport.py`,
`python3 -I`) : copie les nouvelles archives de `SRC` dans `diagnostics/archives/`, en extrait
`resume.json` (`tar --zstd -xOf`), refuse les archives non anonymisées et refait le contrôle des motifs
MAC/IP, range le résumé dans `diagnostics/resumes/`, puis régénère `docs/terrain.md` :

- **clés** (`diag-cle`) : puce et rôle, pilote, liaison, TRIM déclaré et réel, SMART, mesures,
  capacité, cache SLC, catégorie et alertes ;
- **PC** (`nomade-diag`) : modèle, firmware, Secure Boot et présence des CA Microsoft, GPU et pilote,
  rendu logiciel, Wi-Fi, temps de démarrage, erreurs notables ;
- **couples PC × clé**, reliés à la ligne de la clé par son empreinte : liaison sur ce port,
  réinitialisations, mesures comparées à celles de l'hôte. Un même couple diagnostiqué deux fois ne
  garde que le plus récent.

Versionner les résumés : le dépôt est **public**. `resume.json` étant construit sur liste blanche et
contrôlé deux fois, son contenu (modèles de PC et de clés, versions, mesures) ne dit rien des
personnes ; il donne l'historique et rend `docs/terrain.md` reproductible. Les archives complètes,
plus bavardes, restent hors du dépôt.

---

## 6. Réutiliser le code Rust de Fabrique-Clé ou réécrire ?

Ce que couvre l'onglet Diagnostic (`reference/debian/app/src/diagnostic/`, ≈ 2 900 lignes) : la
**clé seule** — identification (sysfs, table, `usb.ids`), mesures en lecture, analyse en écriture,
fiches et catégories. C'est presque tout `diag-cle`, mais rien de `nomade-diag` hors la clé (PC,
firmware, démarrage, mémoire, erreurs).

| | Rust (réutiliser) | Bash (+ `fio`, `jq`) | **Python 3 (réécrire)** |
|---|---|---|---|
| Part reprise | module `diagnostic/`, mais lié à `crate::disques`, `crate::suivi`, `crate::assistant` (pkexec) : il faudrait en tirer une crate commune, donc modifier Fabrique-Clé, projet à part | la table seulement | la table, le parcours sysfs et le protocole, transposés |
| Reste à écrire | tout `nomade-diag` hors mesures, l'archive, l'anonymisation (en Rust ou dans un second langage) | tout | tout, dans un seul langage, partagé par les deux outils et `diag-rapport` |
| Chaîne de construction | édition 2024 → Rust ≥ 1.85 ; Noble fournit 1.75 par défaut : rustup ou paquet versionné dans la VM de build **et sur l'hôte** (`diag-cle`), crates à télécharger, compilation à chaque modification | rien, mais `fio` à ajouter à l'image et à l'hôte | rien : `python3` 3.12 est sur l'hôte et dans l'image, bibliothèque standard suffisante (`json`, `hmac`, `os.preadv`, `mmap`) |
| Retouche sur la clé | impossible sans `cargo` | oui | **oui** : Claude Code lancé sur la clé modifie et relance le script sur place, sur le PC concerné |
| Mesures | les meilleures | `fio` : latences et JSON, mais protocole différent de Fabrique-Clé | transposition fidèle du protocole ; surcoût de quelques µs par opération, à étalonner |
| JSON, empreintes, anonymisation | bon | laborieux (`jq`, `sed`, HMAC par `openssl`) | naturel |

**Recommandation : réécrire en Python 3**, sans dépendance hors bibliothèque standard, lancé par
`python3 -I`. On reprend de Fabrique-Clé, sans son code :
- `fabricants-usb.txt` **copiée telle quelle** (même format, en-tête de provenance et date de copie)
  dans `config/rootfs/usr/share/nomade/` ; une clé rencontrée sur le terrain enrichit les deux copies ;
- le parcours sysfs d'`identifier` (de `block` jusqu'à l'interface USB puis au périphérique) ;
- le protocole de mesure et d'analyse (durées, tailles de blocs, 8 en parallèle, classes de
  l'histogramme, grille de marqueurs, détection de la chute de débit) ;
- les seuils de catégorie A–D et l'estimation à partir des indices.

`usb.ids.zst` n'est pas repris : l'hôte et l'image ont la base hwdb de systemd (`systemd-hwdb query
usb:v090Cp2320`).

L'**AppImage de Fabrique-Clé** fait déjà, sur l'hôte, ce que fera `diag-cle` ; elle ne remplace pas
l'outil (résultat en texte, pas de `resume.json`, deux outils au lieu d'un), mais sert à l'**étalonnage** :
mêmes mesures par les deux sur la même clé, écart consigné. Python ajoute quelques microsecondes par
opération, peu devant les ≈ 200 µs de médiane mesurés sur la clé de 1 To.

Déviation à consigner : `CLAUDE.md` autorise Python « pour l'outillage de test ». `diag-cle` est un
outil de l'hôte et `nomade-diag` un outil embarqué dans le système livré : décision à prendre (D-047)
et phrase de `CLAUDE.md` à élargir (« outillage de test et de diagnostic »). Si l'interface Rust de
« plus tard » voit le jour, elle lira `resume.json` plutôt que de refaire la collecte.

---

## 7. Étapes proposées (un commit, ou plus, par étape)

1. **`NOMADE-DATA`** : paramètres, `data_gib` + essais `make ci`, `deploy.sh` (taille, `fstab`),
   `exfatprogs` dans l'image, autotest E-44, SPEC (E-29, E-44), D-046, README, CHANGELOG ;
   `make all` puis `make deploy-test RUNS=2`.
2. **Module commun et `diag-cle` en lecture seule** : `nomade_diag/` (identification, lecture),
   table copiée, `assert_usb_disk` et ses refus dans `test-guards.sh`, `scripts/diag-cle.sh`,
   `make diag-cle`, `make diag-cle-test`, D-047, D-048 ; essai sur un loop dans la VM.
3. **Analyse complète** (`COMPLET=1`) : capacité, TRIM réel, écritures, courbe, remise à vide ;
   contrefaçon simulée dans `make diag-cle-test` ; SPEC E-45.
4. **`nomade-diag`, collecte et anonymisation** (sans mesures) : script, `selftest.sh --materiel`,
   numéro de série repère dans `test-image.sh`, autotest E-46, `docs/diagnostic.md` ;
   `make test`, `make deploy-test`.
5. **Mesures de `nomade-diag`** (`--mesures`), plafonds.
6. **`make diag-rapport`**, `diagnostics/`, `.gitignore`, `docs/terrain.md` vide ; dans `deploy.sh`,
   verdict du dernier `diag-cle` et `DEPLOY_CLE_EMPREINTE` ; D-049.
7. **Essais réels (Fabien)** : `diag-cle` en lecture seule sur les deux clés ; analyse complète de la
   128 Go puis redéploiement en 0.2 (`NOMADE-DATA` de 11 Gio) ; `nomade-diag` sur la 1 To depuis le
   clone et sur la 128 Go, sur quelques PC ; étalonnage contre Fabrique-Clé ; premier `docs/terrain.md`.

GNOME Logiciels sans service résident (dernière ligne de la 0.2 dans `PLAN.md`) reste un chantier
séparé, indépendant de cette note.

## 8. Questions pour Fabien

Réglé le 2026-11-08 : deux outils, `diag-cle` séparé de `deploy`, en lecture seule par défaut et
complet sur demande.

1. **Plancher de 8 Gio** et seuil « racine ≥ `IMAGE_ROOT_GIB` + 16 Gio » : d'accord ?
2. **Point de montage** `/media/NOMADE-DATA` (chemin fixe, montage par `fstab`), ou préfères-tu la voie
   udisks (`/media/fabien/NOMADE-DATA`, montée au clic) ?
3. **Empreintes des PC** : sel propre à chaque clé (deux clés sur le même PC donnent deux empreintes),
   ou sel de l'hôte copié au déploiement (un même PC reconnu d'une de tes clés à l'autre) ?
4. **`diagnostics/resumes/` versionné** dans le dépôt public : d'accord, ou dépôt séparé / non versionné ?
5. Un **lanceur dans le menu** (« Diagnostic de la clé », qui ouvre un terminal), pour qu'un élève
   lance `nomade-diag` sans taper de commande ? Ou le terminal seulement, pour l'instant ?
6. **Mesures d'écriture de `nomade-diag`** sur la racine (chemin réel, chiffré) avec un plafond de
   1 Gio : d'accord ?
7. **Écriture longue de `diag-cle COMPLET=1`** : 3 min par défaut (≈ 90 Go sur un SSD rapide) ?
8. **SMART** : installer `smartmontools` sur l'hôte (facultatif ; sans lui, `diag-cle` note « non lu ») ?
9. **Python pour ces deux outils** (déviation à la consigne de `CLAUDE.md`) : d'accord ?
