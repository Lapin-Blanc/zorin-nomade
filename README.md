# zorin-nomade

Construit et déploie un **Zorin OS 18 Core installé** (pas un live) sur une clé USB rapide (SSD NVMe
derrière un pont USB), chiffré, démarrable sur n'importe quel PC UEFI, avec ou sans Secure Boot.

**Version 0.1.0-alpha** — utilisée au quotidien par son auteur depuis le 2026-11-08 ; interface
(`make`, `config/project.env`) encore susceptible de changer. Historique : `CHANGELOG.md`.

## Ce que produit l'outil

- Le système de l'ISO officielle Zorin OS 18.1 Core (empreinte vérifiée), installé sans installateur
  graphique, mis à jour, en `fr_BE` (clavier belge jusque dans la question LUKS), sans snapd ni census.
- **Démarre partout** : shim et GRUB signés dans le chemin amovible `EFI/BOOT/BOOTX64.EFI`, aucune
  écriture dans la NVRAM du PC hôte (ni entrée de démarrage, ni dbx, ni firmware), initramfs générique,
  microcodes Intel et AMD.
- **Racine LUKS2** dont la clé de volume est tirée au déploiement, sur la clé elle-même ; `/boot` en clair.
- **Réglé pour une clé USB** : zram (pas de swap sur la clé), `/tmp` en RAM, écritures regroupées,
  journal plafonné, TRIM hebdomadaire, profil Brave en RAM (psd), indexation du contenu coupée,
  services inutiles désactivés. Mises à jour de sécurité automatiques conservées.

Détail des exigences : `SPEC.md` (E-01 à E-43) ; raisons des choix : `DECISIONS.md`.
Mesures sur la clé réelle (USB 10 Gbit/s) : lecture 800 Mo/s, écriture 560 Mo/s, lecture 4K
aléatoire 0,2 ms ; démarrage ≈ 40 s jusqu'à l'écran de connexion, firmware du PC et phrase compris.

## Prérequis

- Une machine Linux de la famille Ubuntu 24.04 (Zorin 18, Ubuntu, Mint…) avec KVM, ≈ **80 Gio** libres
  dans le dossier du dépôt, 7 Gio de RAM au moins.
- Paquets (une fois) :
  ```bash
  sudo apt install qemu-system-x86 qemu-system-gui qemu-utils ovmf cloud-image-utils \
                   openssh-client curl make git zstd shellcheck python3 \
                   bmap-tools cryptsetup exfatprogs gdisk rsync dosfstools
  sudo usermod -aG kvm "$USER"     # accès à /dev/kvm sans root, puis se reconnecter
  ```
- `make doctor` vérifie les outils, KVM, OVMF, l'espace disque et le port de la VM de build ; il
  échoue seulement sur ces points. Il signale aussi, en avertissements `[!!]`, des points de sécurité
  qui ne concernent que le travail avec Claude Code (sudo sans mot de passe, groupes `docker`,
  `libvirt`…) ; `make doctor STRICT=1` les rend bloquants (voir `docs/developpement/README.md`).

## Démarrage rapide

```bash
git clone https://github.com/Lapin-Blanc/zorin-nomade.git && cd zorin-nomade
# ou une version figée : git clone --branch v0.1.0-alpha https://github.com/Lapin-Blanc/zorin-nomade.git
make doctor          # l'hôte est-il prêt ?
cp config/local.env.example config/local.env   # puis y régler compte, langue, clavier, fuseau
make image           # construit out/latest.img (10 à 20 min)
make test            # démarre l'image dans QEMU, Secure Boot activé puis désactivé
ls -l /dev/disk/by-id/ | grep usb          # repérer la clé (disque entier, sans « -part »)
sudo make deploy KEY=/dev/disk/by-id/usb-…  # efface la clé et y déploie l'image
```
Puis dérouler `docs/premier-demarrage.md` au premier démarrage de la clé. `make help` liste les cibles.

## Construire l'image — `make image`

Aucune commande root sur la machine : tout ce qui demande root (loop, montages, chroot, `apt`,
`grub-install`) se fait dans une **VM de build** Ubuntu 24.04 jetable (QEMU en mode utilisateur, SSH sur
`127.0.0.1:2222`), créée au premier `make image`.

1. `make iso` télécharge l'ISO Zorin dans `cache/` et vérifie son SHA-256 (`config/iso.env`).
2. La VM décompresse le squashfs, retire ce que l'installateur Zorin aurait retiré, met tout à jour,
   applique l'overlay `config/rootfs/` et les réglages, installe GRUB, contrôle le résultat.
3. L'image revient dans `out/` : `zorin-nomade-<AAAAMMJJ-HHMM>.img` (fichier creux : ≈ 27 Gio apparents,
   ≈ 7 Gio alloués), `.bmap`, `.sha256`, `.manifest` (liste des paquets), lien `out/latest.img`.
   Les `KEEP_IMAGES` dernières images sont gardées. Journal : `out/logs/build-*.log`.

Durées : ≈ 10 min avec le cache APT de la VM, ≈ 20 min depuis zéro (`make builder-destroy && make all`).
La VM se jette sans risque (`make builder-destroy`) : rien d'important n'y vit.

## Tester

- `make test` : démarre `out/latest.img` dans QEMU (clé simulée en USB, NVRAM vierge), Secure Boot activé
  puis désactivé. Un autotest embarqué, inerte sur un vrai PC, vérifie plus de 100 points et écrit
  `RESULT=PASS|FAIL` dans `out/test/<essai>/serial.log` ; capture d'écran `screen.png`.
- `make test-gui` : la même image dans une fenêtre, pour regarder.
- `make deploy-test` : déploiement chiffré complet sur un fichier de 64 Gio dans la VM de build, rejoué
  deux fois, puis démarrage avec la phrase tapée au clavier virtuel (≈ 15 min).

## Déployer sur une clé — `sudo make deploy KEY=…`

`scripts/deploy.sh` (≈ 10 min sur une clé USB 3) :

1. affiche modèle, numéro de série et taille de la clé et fait **taper le numéro de série** avant
   d'écrire quoi que ce soit ; refuse tout disque qui n'est pas un disque USB entier, ou qui porte le
   système de la machine ;
2. demande la **phrase de passe LUKS** (deux fois, ASCII uniquement : elle se tape en clavier belge au
   démarrage) puis le **mot de passe** du compte ;
3. essaie le TRIM à travers le pont USB, efface la clé, écrit l'image (`bmaptool`), agrandit la racine
   jusqu'au bout de la clé (moins `DEPLOY_DATA_GIB` pour une partition exFAT `NOMADE-DATA` lisible sous
   Windows), la recrée chiffrée en LUKS2 et y copie le système, règle l'initramfs, GRUB et la règle udev
   du pont, contrôle tout, puis affiche les premiers points de `docs/premier-demarrage.md`.

**Un déploiement efface toute la clé**, `/home` compris. Le déploiement peut se lancer depuis une autre
clé nomade, jamais vers le disque d'où le système a démarré.

### Paramètres principaux (`config/project.env`, surcharges dans `config/local.env`)

Les valeurs par défaut sont celles de Fabien. Pour les changer sans toucher au dépôt :
`cp config/local.env.example config/local.env`, puis décommenter les lignes voulues. Les réglages du
système (compte, langue, clavier, fuseau) comptent au `make image` suivant ; ceux du déploiement, au
`make deploy` suivant.

| Paramètre | Défaut | Rôle |
|---|---|---|
| `TARGET_USER`, `TARGET_HOSTNAME` | `fabien`, `zorin-nomade` | compte et nom de la machine |
| `TARGET_LOCALE`, `TARGET_KEYMAP`, `TARGET_TIMEZONE` | `fr_BE.UTF-8`, `be`, `Europe/Brussels` | langue, clavier, fuseau |
| `DEPLOY_ENCRYPT` | `1` | racine chiffrée en LUKS2 |
| `DEPLOY_DATA_GIB` | `0` | taille de la partition exFAT `NOMADE-DATA` (0 : aucune) |
| `DEPLOY_INODE_RATIO` | `65536` | octets par inode de la racine recréée |
| `KEEP_IMAGES` | `2` | images gardées dans `out/` |

## Entretenir une clé déployée

- **Mises à jour** : les mises à jour de sécurité s'installent seules (`unattended-upgrades`) ; après
  quelques jours sans démarrer, la première session les rattrape en arrière-plan. Pour le reste :
  `sudo apt update && sudo apt full-upgrade`. Les mises à jour de GRUB et de shim maintiennent le chemin
  amovible (`sudo ls /boot/efi/EFI/BOOT` : pas de `fbx64.efi`). Éteindre normalement : dpkg écrit sans
  `fsync` (clé jamais arrachée).
- **Firmware de son propre PC** : fwupd est masqué pour ne jamais flasher le PC d'un autre ;
  `sudo systemctl unmask fwupd.service`, mettre à jour, puis `sudo systemctl mask fwupd.service`.
- **Appliquer un changement de `config/` sans redéployer** : pas encore outillé (objectif de la 0.2,
  `nomade-update`). En attendant, reproduire le changement à la main sur la clé, comme pour les
  correctifs du 2026-11-08 (`docs/JOURNAL.md`).
- **Redéployer** : seulement si nécessaire (nouvelle version de Zorin, changement de partitionnement ou
  de chiffrement). Pousser d'abord tout dépôt git présent sur la clé et sauvegarder `/home` : le
  déploiement repart de zéro.

## Dépannage

- **Secure Boot activé et clé refusée** : le shim est signé par « Microsoft Corporation UEFI CA 2011 ».
  Certains PC récents (« Secured-core ») ne font pas confiance à cette autorité tant qu'une option du
  firmware n'est pas activée (par exemple HP : « Enable MS UEFI CA key » ; Lenovo : « Allow Microsoft
  3rd Party UEFI CA »). C'est le cas du HP ProBook 455 G10. Sinon, désactiver Secure Boot. Les
  certificats Microsoft de 2011 expirent en 2026 : surveiller les mises à jour de `shim-signed`.
- **Heure fausse d'une heure (deux en été)** : la clé suppose une horloge matérielle en heure locale,
  comme Windows. Sur un PC dont l'horloge est en UTC (Linux, Mac), l'heure se corrige à la première
  synchronisation réseau ; la clé ne réécrit jamais l'horloge du PC.
- **Disque qui se déconnecte** (`journalctl -k | grep -i uas_eh`) : ajouter
  `usb-storage.quirks=090c:2320:u` (VID:PID du pont) à la ligne du noyau, depuis le menu GRUB (touche
  `e`) pour essayer, puis dans `/etc/default/grub.d/` et `sudo update-grub`.
- **Système qui ne démarre plus** : menu GRUB (3 s) → options avancées → mode de dépannage.

## Limites connues (alpha)

- UEFI uniquement (pas de BIOS hérité) ; pas de pilote graphique propriétaire (NVIDIA : nouveau).
- Phrase de passe LUKS en ASCII uniquement.
- Un redéploiement efface `/home` ; aucun outil de mise à jour de la configuration d'une clé déployée.
- Pas encore essayé : mise en veille, PC avec Secure Boot actif, matériel NVIDIA.
- Ponts USB essayés : Silicon Motion SM2320 `090c:2320` (SSK 1 To, contrôleur de SSD USB natif, UAS,
  TRIM) et VIA Labs `2109:0715` (SSK 128 Go, probablement un VL715 vers SSD SATA). Pour ce dernier, le noyau ignore UAS (`usb-storage`) et le pont refuse le TRIM : la clé
  fonctionne, sans TRIM et avec des écritures plus lentes (≈ 225 Mio/s). `deploy.sh` le détecte et
  règle la clé en conséquence.
- L'image n'est pas publiée : elle se construit localement (`DECISIONS.md`, D-043).

## Intégration continue (GitHub Actions)

- `lint.yml`, à chaque push : `make ci` (shellcheck et refus attendus des garde-fous).
- `image.yml`, quand `scripts/`, `config/`, le `Makefile` ou le workflow changent, et à la demande
  (*Actions* → *image* → *Run workflow*) : construction directement sur le runner, puis `make test`.
  Artefact `diagnostic` : journaux, sortie série, captures, manifeste — pas l'image.
- Restent locaux : `make deploy`, `make deploy-test`, `make test-gui`.

## Développement

Le projet est développé avec Claude Code : `CLAUDE.md` (consignes, lu automatiquement), `PLAN.md`
(feuille de route), `DECISIONS.md`, `docs/JOURNAL.md`, `docs/iso-notes.md`. Mode d'emploi pour faire
évoluer l'outil et histoire de sa construction : `docs/developpement/README.md`.

## Structure

```
README.md CHANGELOG.md                   mode d'emploi, versions
SPEC.md DECISIONS.md PLAN.md CLAUDE.md   système visé, choix, feuille de route, consignes de Claude
Makefile                                 point d'entrée (make help)
config/project.env, config/iso.env       paramètres (config/local.env : surcharges non versionnées)
config/rootfs/                           overlay copié dans le système cible
config/packages/                         paquets gardés, ajoutés, retirés
config/templates/                        modèles remplis au déploiement
builder/                                 cloud-init de la VM de build
scripts/                                 lib, doctor, VM de build, ISO, build, tests, déploiement
scripts/vm/                              scripts root (VM de build ou runner CI)
docs/premier-demarrage.md                checklist d'une clé fraîchement déployée
docs/JOURNAL.md docs/iso-notes.md        journal de développement, constats sur l'ISO
docs/developpement/                      guide de développement, historique de la 0.1
cache/ out/ .builder/ reference/         non versionnés
```
