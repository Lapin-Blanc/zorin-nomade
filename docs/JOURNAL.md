# Journal

Entrées courtes, les plus récentes en bas. Format : `## AAAA-MM-JJ HH:MM — phase / sujet`,
puis ce qui a été fait, ce qui a échoué et pourquoi, et la suite prévue.

## 2026-11-07 — base du projet
Archive de départ préparée avec Fabien : documentation, VM de build, harnais de test,
overlay de configuration, autotest. Scripts de build et de déploiement à écrire (phases 1 et 3).

## 2026-11-07 11:10 — phase 0 / hôte et dépôt
`make doctor` : outils, KVM, OVMF, espace (111 Gio) en ordre ; [KO] attendu sur les groupes
`docker`/`libvirt`, gardés par Fabien (D-019). `.claude/settings.json` sans règles `deny`
(laissé tel quel). Hôte à 7 Gio de RAM → VM ramenées à 3 Gio (D-016). `git init` (identité
locale « Fabien Toune », noreply GitHub), commit de base fidèle à l'archive.

## 2026-11-07 11:15 — phase 0 / référence Debian
Lu (pendant le téléchargement) `docs/lecons.md`, `architecture.md`, `construire-image.sh`,
`tester-image.sh`, `image.yml`. Conventions reprises ou écartées : D-015. CI complète retenue
avec Fabien (D-023).

## 2026-11-07 11:20 — phase 0 / ISO et VM de build
Dernière ISO : Zorin OS 18.1 Core (2026-04-14), empreinte relevée sur la page d'aide Zorin et
recoupée avec le miroir (D-013). `make iso` : 7 min 30, empreinte vérifiée. `make builder` : 2 min
(image cloud + cloud-init `done`), 94 Gio libres dans la VM, tous les outils présents. Copie de
l'ISO dans la VM : 22 s. Piège de méthode : une boucle `until ! pgrep -f fetch-iso.sh` se trouve
elle-même (le motif est dans sa propre ligne de commande) : attendre sur le PID, ou `pgrep -x`.

## 2026-11-07 11:45 — phase 0 / inspection de l'ISO
Schéma Ubiquity à couche unique (`filesystem.squashfs` + `manifest-remove` de 255 paquets),
noyau 6.17.0-20 (7.0.0-42 après mise à jour), Brave au lieu de Firefox, snapd sans snap, Tracker 3.7,
pas de profil dconf `user`, os-prober actif par défaut, `resolv.conf` en lien vers `/run` (premier
essai de simulation sans DNS pour cette raison). Simulation APT en chroot : 231 purges sans
cascade, `full-upgrade` de ≈ 1,7 Go. Détails : `docs/iso-notes.md`. Clés dconf corrigées
(Tracker, D-020) et validées par `gsettings` dans le chroot ; `GRUB_DISABLE_OS_PROBER=true` (D-026).

## 2026-11-07 11:50 — phase 0 / décisions avec Fabien et plan
Brave + définition psd (D-021, E-25), mises à jour de sécurité auto gardées (D-022), census retiré
(D-025, E-39), quatre services désactivés (D-024, E-40), CI complète (D-023, E-42). SPEC, PLAN
(phases 1 à 5) et `docs/A-FAIRE-FABIEN.md` mis à jour. Fin de la phase 0 : arrêt pour validation.
La VM de build est arrêtée (disque et ISO conservés dans `/work/iso`).

## 2026-11-07 19:00 — phase 1 / premier build
Scripts écrits : `config/packages/*.list`, `scripts/vm/build.sh` (root, VM ou CI), `scripts/build-image.sh`
(orchestration, rapatriement creux en flux zstd), contrôle mémoire de `test-image.sh` (D-016).
Avant le run, RAM libérée sur l'hôte (Brave, VS Code, GNOME Logiciels fermés, accord de Fabien).
Essai de `grub-install` en chroot jetable : pas de `--force-extra-removable` sous Ubuntu, `grubx64.efi`
absent de `EFI/BOOT` → script de synchronisation + crochet APT (D-029).
1er build : échec au contrôle EFI (dossier inattendu) ; noyau 6.17 non retiré par `autoremove`
(purge explicite ajoutée). 2e build : passe ; `make test` : écran de connexion GNOME atteint avec
Secure Boot activé et désactivé (≈ 1 min chacun).

## 2026-11-08 00:40 — phase 1 / corrections et sonde des mises à jour
Analyse du dossier `EFI/grub` : `/etc/default/grub` supprimé par la purge de `grub-pc` → restauré
(D-032), retour à `EFI/ubuntu` et au menu « Zorin ». Le cache APT était vidé par `apt-get clean`
avant démontage → corrigé. Faux échec E-10 sans Secure Boot (variable absente lue « unknown ») →
corrigé dans l'autotest. Sonde (choix b de Fabien) sur une copie jetable de l'image dans la VM :
réinstallation de shim et GRUB par APT → `EFI/BOOT` reste cohérent, mais `grub-install` tente
d'écrire en NVRAM (update_nvram ignoré) → déviation de `grub-install` vers une enveloppe
`--no-nvram` et mise à jour simulée intégrée au build, bloquante (D-033).

## 2026-11-08 09:00 — phase 1 / acceptation
Build en 5 min (cache APT réutilisé), image de 6,8 Gio alloués / 28 Gio. `make test` : les deux
essais atteignent `graphical.target` et l'écran de connexion GNOME (captures vérifiées), 48 PASS
chacun ; restent E-21 (`/tmp` en tmpfs) et E-26 (dconf), prévus en phase 2. Journal `-p err` vide.
Phase 1 terminée. Note : mémoire de l'hôte de nouveau juste (2,8 Gio libres après arrêt de la VM
de build), l'essai a quand même tenu.

## 2026-11-08 09:45 — phase 2 / réglages et autotest
Ajouts au build : `tmp.mount` (D-038), psd global, profil dconf `user` + `dconf update` (valeurs
relues par `gsettings` au build), E-40 (`systemctl disable`), `check-language-support -l fr` (rien à
installer), manifeste copié dans `/etc/nomade/packages.manifest`. Overlay : définition psd Brave,
profil dconf, `conf.d/60-nomade-keymap`. Autotest étendu (E-04, E-08, E-09 complet, E-11, E-15, E-17,
E-20, E-22, E-25 à E-27, E-39 à E-41) et contrôles « clé déployée » pour la phase 3.
Trois faux départs : (1) lien psd absolu testé par `-e` hors chroot → `-L` ; psd était déjà activé
globalement par son paquet ; (2) `lsinitramfs | grep -q` sous `pipefail` (SIGPIPE) → variable ;
(3) `KEYMAP=y` sans effet sous Ubuntu, le crochet `console_setup` embarque toujours la disposition →
contrôle sur `cached_UTF-8_del.kmap.gz` (D-034). `whoopsie.service` est « static » (déclenché par
`whoopsie.path`) : l'autotest l'admet s'il est inactif.

## 2026-11-08 09:56 — phase 2 / acceptation
Build en 10 min, image 6,8 Gio alloués. `make test` : `RESULT=PASS` avec Secure Boot activé et
désactivé, 103 contrôles chacun, journal `-p err` vide, écran de connexion GNOME (en français).
Phase 2 terminée. Les contrôles « clé déployée » sont en place pour la phase 3.

## 2026-11-08 10:10 — phase 3 / déploiement
`scripts/deploy.sh` (recréation LUKS2 + rsync, D-035 ; détails D-036), `scripts/deploy-test.sh`,
`test-image.sh --encrypted` (question détectée par l'inactivité du disque, D-037). 1er essai : faux
échec sur les drapeaux LUKS (tabulation dans la sortie de `luksDump`) → blancs normalisés. 2e essai
(image de la phase 2) : déploiement en 2 min 44 s dans la VM, fichier rapatrié 7,9 Gio alloués / 64 ;
question LUKS détectée à ≈ 22 s, phrase tapée en touches AZERTY (`a`→`q`, `z`→`w`, `m`→`;`) et
acceptée en 3 s : disposition `be` prouvée dans l'initramfs ; 117 PASS, seule la ligne des drapeaux
échouait (même bug d'analyse, dans l'autotest embarqué) → reconstruction de l'image et essai final
avec deux déploiements successifs (E-34).

## 2026-11-08 10:35 — phase 3 / acceptation
Image reconstruite (autotest corrigé), puis `make deploy-test RUNS=2` : deux déploiements successifs
sur le même fichier de 64 Gio (2 min 53 s et 3 min 26 s ; deux volumes LUKS2 d'UUID différents :
clé de volume tirée à chaque fois ; TRIM accepté → règle `unmap`), fichier rapatrié 7,9 Gio alloués.
Démarrage : question détectée à 24 s, phrase acceptée en 3 s (touches AZERTY), `RESULT=PASS` avec
Secure Boot activé et désactivé, 118 contrôles (racine dm-crypt, drapeaux LUKS persistants,
`discard`, règle udev appliquée, racine agrandie, compte déverrouillé). Aucun secret dans les
journaux (contrôlé par `deploy-test.sh`). Phase 3 terminée.

## 2026-11-08 10:40 — phase 4 / CI
`image.yml` : déclenché par `scripts/**`, `config/**`, `Makefile`, le workflow, et à la demande ;
espace libéré, outils, KVM (règle udev), `make ci`, ISO en `actions/cache` (restauration puis
enregistrement immédiat après téléchargement), `sudo scripts/vm/build.sh` sur le runner (shell
`bash -eo pipefail` pour que `| grep` ne masque pas un échec), `make test`, synthèse dans le résumé
du job, artefact `diagnostic` (journaux, série, captures, manifeste ; pas d'image). `lint.yml` lance
`make ci`, qui ajoute `scripts/test-guards.sh` (16 refus attendus des garde-fous, sans root).
Validation locale : YAML chargé, étapes `run` passées à shellcheck (`actionlint` absent de l'hôte).
Pas de dépôt GitHub : rien n'est poussé ; marche à suivre dans `docs/A-FAIRE-FABIEN.md`.

## 2026-11-08 10:55 — phase 5 / reproductibilité, premier essai
Clone propre dans un dossier temporaire profond, VM détruite : construction depuis zéro réussie
(VM neuve, cache APT vide, ≈ 15 min), mais les deux essais QEMU échouent en 3 s : le chemin du socket
QMP (`out/test/sb-on/qmp.sock` sous un chemin long) dépasse la limite de 108 octets des sockets Unix.
Défaut invisible dans le dépôt principal (chemin court). Correction : sockets dans
`$XDG_RUNTIME_DIR/nomade-qmp.XXXXXX`. Chaîne complète relancée depuis le clone mis à jour.

## 2026-11-08 11:15 — phase 5 / acceptation et rapport
Clone propre mis à jour (`6b00b2d`), `make builder-destroy && make all` : 19 min 26 s, VM neuve, build
en 13 min avec cache APT vide, `RESULT=PASS` (103 contrôles) avec et sans Secure Boot. E-38 tenue.
Clone et sa VM supprimés ; la VM du dépôt principal aussi (recréée au prochain `make image`).
`docs/RAPPORT.md` écrit (résultats, déviations, limites, checklist du premier démarrage natif).
Contrôle de présence de l'ISO dans la VM rendu silencieux (message « FAILED open or read »
trompeur). Fin du run autonome : phases 0 à 5 terminées.

## 2026-11-08 12:00 — clé déployée, évaluation sur matériel réel
Session Claude Code lancée **sur la clé** (HP ProBook 455 G10, Ryzen 3 7330U, 7 Gio, port USB
10 Gbit/s, pont `090c:2320` en `uas`, Secure Boot désactivé ; premier démarrage). Mesures :
lecture séquentielle 800–830 Mo/s, écriture 560 Mo/s, 4K aléatoire QD1 médiane 0,20 ms (p99 0,28 ms,
≈ 4 900 IOPS), `fdatasync` ≈ 1 ms, AES-XTS 1,7 Gio/s. Démarrage : firmware 16,3 s, GRUB 7,3 s (3 s de
menu + ≈ 4 s pour 100 Mo de noyau et d'initramfs), clé vue à 1,3 s, racine montée à 15,4 s (phrase
LUKS), `graphical.target` 10,6 s plus tard. Session GNOME ≈ 1 Gio PSS + ≈ 0,25 Gio de services ;
zram 3,5 Gio (zstd), zswap coupé. Tous les réglages E-19 à E-27 et E-40 constatés en place.
Constats : (1) `DEPLOY_DISCARD=0` alors que `fstrim -v /` réduit 927,7 Gio sans erreur : l'essai de
`deploy.sh` appelait `blkdiscard` sans `-f` ; util-linux 2.39 refuse quand stdin est un terminal et
que le disque porte une signature (message masqué par `2>/dev/null`) ; invisible en test (stdin = tube).
Impact faible : p3 TRIMée avec `-f`, le noyau de la clé active lui-même `provisioning_mode=unmap`.
(2) ≈ 12 Gio écrits par `ext4lazyinit` la première demi-heure (62,3 M d'inodes, 0,28 M utilisés).
(3) Profil Brave de 343 Mo dans `/run/user/1000` plafonné à 725 Mo. (4) `secureboot-db.service` écrit
db/dbx dans la NVRAM du PC si elles lui manquent (rien ici) ; fwupd propose les firmwares du PC.
(5) La db de ce HP n'a pas « Microsoft Corporation UEFI CA 2011 », qui signe le shim : refus avec
Secure Boot actif tant que l'option du firmware est coupée. (6) RTC du HP en UTC (Zorin interne) : la
clé (LocalRTC) démarre avec 1 h de retard jusqu'à la synchro NTP (78 s), sans réécrire le RTC.

## 2026-11-08 12:50 — correctifs (branche `correctifs-cle`, préparée sur la clé)
GitHub injoignable depuis la clé : commits locaux, à pousser plus tard. Ni `make`, ni QEMU, ni OVMF sur
la clé : shellcheck 0.9.0 extrait sans root du paquet Ubuntu (`apt-get download`) et lancé comme
`make lint` ; `scripts/test-guards.sh` passe. Construction et tests QEMU **non relancés** : à faire sur
l'hôte (PLAN phase 6). Changements : essai de TRIM corrigé (`-f`, `</dev/null`, cause consignée) et
exigé par `deploy-test.sh` ; `DEPLOY_INODE_RATIO=65536` (D-041) ; `logind.conf.d` à 25 % (D-040) ;
masquage `secureboot-db`/`fwupd` (D-042, E-43) ; autotest + 5 contrôles ; README (Secured-core) et
checklist (veille). Sur la clé : script à chaud fourni à Fabien (mêmes réglages + règle udev et
`deploy-info` corrigés) ; GNOME Logiciels sans lancement automatique (`~/.config/autostart`).

## 2026-11-08 13:10 — correctifs à chaud vérifiés après redémarrage
Script lancé par Fabien, puis redémarrage de la clé : `secureboot-db.service`, `fwupd.service`,
`fwupd-refresh.timer` masqués ; `/run/user/1000` à 1,8 Gio (25 %) ; règle udev avec
`provisioning_mode=unmap` ; `DEPLOY_DISCARD=1` annoté ; GNOME Logiciels absent de la session.
Deuxième démarrage : firmware 11,7 s, GRUB 7,4 s, noyau 11,2 s (phrase LUKS comprise), espace
utilisateur 10,0 s.

## 2026-11-08 13:25 — CI `image` : premier run sur GitHub (PR #1)
Lint vert. Construction réussie sur le runner en 6 min (`masqués : secureboot-db.service fwupd.service
fwupd-refresh.timer`), mais `make test` refuse : « /dev/kvm inaccessible ». L'étape KVM du workflow avait
mis `/dev/kvm` en 0666 avant la construction ; pendant le `full-upgrade` dans le chroot, le postinst de
`udev` lance `systemd-tmpfiles --create static-nodes-permissions.conf` (`z /dev/kvm 0660 - kvm -`) sur le
`/dev` du runner, monté dans le chroot, et l'utilisateur du runner perd l'accès. Sans effet dans la VM de
build (les tests tournent sur l'hôte). Correction : l'étape KVM passe juste avant `make test` et
vérifie l'accès.

## 2026-11-08 13:40 — CI `image` verte
Run 42480117641 (commit `a078949`) : construction 6 min, `make test` → `RESULT=PASS` avec Secure Boot
activé (78 s) et désactivé (72 s), 107 contrôles dont les nouveaux E-25 (`/run/user` à 25 %) et E-43
(3 unités masquées) ; capture : écran de connexion GNOME. Reste `make deploy-test` sur l'hôte (contrôle
E-30 des inodes, essai de TRIM aux deux passages) avant la fusion de la PR #1.

## 2026-11-08 14:30 — le dépôt devient l'outil (branche `outil-alpha`, D-044)
Constat avec Fabien : le code est un outil fonctionnel (alpha), mais le README et les fichiers de tête
décrivaient le chantier (archive de base, phase 0, run autonome). Réorganisation : README en mode
d'emploi, `docs/premier-demarrage.md`, `docs/developpement/` (guide, `prompts/`, rapport du run, plan
v0.1 déplacés par `git mv`), `PLAN.md` en feuille de route (0.1.0-alpha, 0.2 « entretien d'une clé
déployée », plus tard), `CLAUDE.md` recadré, `docs/A-FAIRE-FABIEN.md` à jour, `CHANGELOG.md`. Version
0.1.0-alpha : `PROJECT_VERSION`, `NOMADE_VERSION` (build-info, contrôle E-08), `DEPLOY_VERSION`,
`make help`. Branche partie de `correctifs-cle` (PR #1 pas encore fusionnée).

## 2026-11-08 15:26 — sur l'hôte : `make image` et `make deploy-test RUNS=2` verts (`outil-alpha`)
Branche `outil-alpha` (`aceb0ec`, contient les PR #1 et #2). `make image` : 12 min, image
`zorin-nomade-20261108-1457` (6,8 Gio alloués, 28 Gio apparents). `make deploy-test RUNS=2` : deux
déploiements chiffrés de suite sur le fichier de 64 Gio (2 min 55 s, 3 min 7 s), « TRIM : essai réussi »
aux deux passages (le second sur une cible déjà partitionnée), aucun secret de test dans le journal ;
démarrage avec phrase saisie au clavier virtuel : `RESULT=PASS` Secure Boot activé (96 s) et désactivé
(102 s), 124 contrôles dont E-30 (65536 octets par inode) et E-08 (version de l'outil dans `build-info`).
Défaut cosmétique relevé, non corrigé : au premier passage, `deploy-test.sh:74` affiche « Aucun fichier
ou dossier » (`2>/dev/null` placé après `<"$logf"` ne couvre pas l'erreur de redirection) ; la valeur
de repli `0` est juste. `git fetch` en SSH refusé par l'agent (clé non déverrouillée) ; les branches
locales correspondaient déjà aux têtes des PR (vérifié avec `gh`).

## 2026-11-08 15:32 — outil utilisable par simple clonage (D-045)
`host-doctor.sh` : garde-fous Claude (sudo sans mot de passe, groupes équivalents à root) en
avertissements, bloquants avec `--strict` (`make doctor STRICT=1`) ; vérifié sur l'hôte : code 0 sans
`STRICT`, échec avec (groupe `docker`). `config/local.env.example` ; README : clonage HTTPS, variante
`--branch`, étape `local.env`. `deploy-test.sh:74` : comptage des lignes du journal sans l'erreur
cosmétique du premier passage. Feu vert de Fabien pour fusionner les PR #1 et #2 après la CI.

## 2026-11-08 15:55 — PR #1 et #2 fusionnées ; feuille de route 0.2 revue
PR #1 fusionnée (`ddf6458`). Incident : `gh pr merge 1 --delete-branch` a supprimé `correctifs-cle`,
base de la PR #2, que GitHub a **fermée** au lieu de la rebaser sur `main`. Réparé : branche recréée
sur son ancien commit (`f9fa568`), PR #2 rouverte, base passée à `main`, branche supprimée de nouveau ;
CI verte, PR #2 fusionnée (`571a199`). Leçon : pour des PR empilées, changer la base de la PR
dépendante (`gh pr edit --base main`) **avant** de supprimer la branche de la première. La branche
distante `outil-alpha` reste à supprimer (refusée par le mode automatique de Claude Code).
Avec Fabien : 0.2 « retours du terrain » (`NOMADE-DATA` par défaut à 10 %, `nomade-diag`, rapport
comparatif, GNOME Logiciels) ; `nomade-update` et le redéploiement sans perte au second plan, sans
version prévue : les tests grandeur nature décideront des versions suivantes.

## 2026-11-08 17:00 — premier déploiement réel sur une clé SSK de 128 Go
Par Fabien depuis `main`, image `zorin-nomade-20261108-1555` (reconstruite par lui, mêmes scripts de
construction que l'image validée), sortie gardée par `tee`. Clé SSK « Portable SSD 128GB » : pont VIA
Labs `2109:0715` (« VL817 SATA Adaptor » pour `lsusb`, mais le VL817 est un concentrateur : probablement
un VL715), SSD SATA, 10 Gbit/s négociés. Le noyau ignore UAS pour ce pont (quirk intégré,
`usb-storage`) ; `rotational=1` vu par le noyau, corrigé par la règle udev. Essai de TRIM : `blkdiscard
-f` atteint le périphérique, refusé par le pont (« Illegal Request », EIO) → `DEPLOY_DISCARD=0`, règle
sans `provisioning_mode` ; la cause réelle s'affiche (correctif de la PR #1). Écriture `bmaptool`
225 Mio/s (560 sur la clé de 1 To), déploiement en 3 min 57 s, contrôles finaux sains. Démarrage et
contrôles du premier démarrage conformes (Fabien). Le port (USB-A ou USB-C) n'aurait rien changé :
UAS, TRIM et vitesse maximale dépendent du pont. Correctif : `deploy.sh` relève le pilote USB
(`DEPLOY_USB_DRIVER`) et adapte le récapitulatif, qui annonçait toujours `uas` ; `make deploy-test` vert
(124 contrôles, Secure Boot activé et désactivé).

## 2026-11-08 17:25 — table des ponts du projet Fabrique-Clé (`reference/debian`)
Lu à la demande de Fabien : l'onglet Diagnostic de l'application Rust (`app/src/diagnostic/`,
`docs/architecture.md`) couvre déjà une bonne part de `nomade-diag` côté clé (pilote, liaison négociée,
TRIM, file de commandes, rotatif déclaré, ordonnanceur ; lectures directes bornées en durée ; écriture
sur l'espace libre par fichier délié, sans effacer ; fiches lu/mesuré/déduit/non mesuré). Sa table
`fabricants-usb.txt` corrige deux erreurs de la journée : `090c:2320` est un Silicon Motion SM2320
(contrôleur de SSD USB natif, pas un SSD NVMe derrière un pont), `2109:0715` probablement un VL715
(le nom `lsusb` « VL817 » désigne un concentrateur). Corrigé dans README, PLAN, CHANGELOG, A-FAIRE.

## 2026-11-08 18:00 — ouverture de la 0.2 et note de conception (branche `retours-terrain`)
`PROJECT_VERSION=0.2.0-alpha`, « Non publié » dans `CHANGELOG.md` ; `docs/A-FAIRE-FABIEN.md` sans
l'étiquette (posée) ni la branche distante `outil-alpha` (déjà absente de GitHub, vérifié par
`git ls-remote`). Note `docs/developpement/conception-0.2.md` soumise à Fabien : `NOMADE-DATA` à 10 %
(plancher 8 Gio) montée par `fstab` (UUID, `uid=1000`, `nofail`) et `exfatprogs` dans l'image ;
`nomade-diag` réécrit en Python (bibliothèque standard) en reprenant de Fabrique-Clé la table des
puces, le parcours sysfs et le protocole de mesure, pas le code Rust (lié à `disques`, `suivi`,
`assistant` ; Rust ≥ 1.85 absent de Noble ; pas de `cargo` sur la clé) ; anonymisation sur liste
blanche avec empreintes salées par clé ; `make diag-rapport` vers `docs/terrain.md`. Constats : l'image
a `python3`, `jq`, `zstd`, `mokutil`, `dmidecode`, `mesa-utils`, mais ni `exfatprogs` ni `fio`.

## 2026-11-08 18:30 — note de conception révisée : deux diagnostics
Précision de Fabien : un diagnostic **depuis l'hôte, avant le déploiement**, pour éprouver la clé à
fond, et un autre **depuis le système déployé**, qui sauvegarde son rapport. La première version ne
prévoyait que le second. Ajouté : `make diag-cle KEY=…`, outil séparé de `deploy`, en lecture seule
par défaut (identification sans root, lectures directes avec `sudo`, nouvelle garde
`assert_usb_disk` sans saisie du numéro de série) et complet sur demande (`COMPLET=1`, garde
`assert_real_usb_target` inchangée : capacité réelle, TRIM réel, écritures, cache SLC, remise à
vide) ; essais sur loop et contrefaçon simulée par device-mapper dans la VM. Module Python commun aux
deux outils ; empreinte de la clé calculée par l'hôte et transmise par `deploy-info`. `smartctl`
absent de l'hôte (SMART facultatif).

## 2026-11-08 18:45 — questions de la note tranchées (D-046 à D-049)
Avec Fabien, une par une : plancher de 8 Gio et seuil de 40 Gio pour la racine ; `fstab` sur
`/media/NOMADE-DATA` ; sel de l'hôte copié sur la clé ; résumés et `docs/terrain.md` versionnés ;
lanceur dans le menu ; écritures de `nomade-diag` sur la racine, plafond 1 Gio ; écriture longue de
`diag-cle` ramenée à **1 min** (proposé : 3) ; `smartmontools` sur l'hôte ; Python, `CLAUDE.md`
élargi. Note, `PLAN.md`, `CLAUDE.md` et `docs/A-FAIRE-FABIEN.md` mis à jour. Prochaine étape :
`NOMADE-DATA` (étape 1 de la note), sur feu vert.
