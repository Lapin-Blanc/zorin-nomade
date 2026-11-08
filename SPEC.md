# Spécification du système cible

Les exigences sont numérotées (E-xx). Une déviation doit être justifiée dans `DECISIONS.md`.
Les valeurs paramétrables (utilisateur, tailles, locale…) sont dans `config/project.env`.

## 1. Contexte d'usage

- Support : clé USB SSK contenant un SSD NVMe derrière un pont USB (UAS attendu).
- La clé n'est **jamais débranchée à chaud**.
- Ports **USB 3.0 minimum**, souvent USB-C.
- Machines hôtes : **UEFI** (Secure Boot activé ou non), **8 Gio de RAM minimum**, matériel
  varié (Intel/AMD, iGPU, parfois NVIDIA), souvent des PC Windows.
- Priorités, dans l'ordre : **1) démarre partout**, **2) réactivité**, **3) longévité du SSD**,
  4) facilité de maintenance (mêmes recettes pour la future série Zorin 19, GNOME aussi).

## 2. Base

- E-01 **Zorin OS 18.x Core** (GNOME), dernière version publiée, ISO officielle vérifiée par
  SHA-256 (valeur publiée par Zorin, relevée en phase 0 dans `config/iso.env`).
- E-02 **Système installé**, pas un live : aucune trace de casper, de l'installateur
  (Ubiquity/Subiquity/surcouche Zorin) ni de l'utilisateur live.
- E-03 Construction **sans installateur graphique** : le système est produit à partir du
  squashfs de l'ISO (couches combinées comme le ferait l'installateur), puis configuré en chroot.
- E-04 Dépôts Zorin/Ubuntu conservés ; `apt full-upgrade` au build ; manifeste des paquets
  (`dpkg-query`) livré avec l'image.
- E-39 `zorin-os-census` retiré (équivaut à décocher la case « census » de l'installateur Zorin :
  aucune installation comptée chez Zorin). (D-025)

## 3. Image produite (artefact de build, non chiffrée)

- E-05 Fichier brut `out/zorin-nomade-<AAAAMMJJ-HHMM>.img` + `.bmap` + `.manifest` + `.sha256`,
  et lien `out/latest.img` vers la dernière image. Journal de build dans `out/logs/`.
- E-06 Table GPT :
  | n° | rôle | taille | FS | étiquette |
  |----|------|--------|----|-----------|
  | 1 | ESP | `IMAGE_ESP_MIB` (1 Gio) | FAT32 | `NOMADE-ESP` |
  | 2 | /boot | `IMAGE_BOOT_MIB` (2 Gio) | ext4 | `nomade-boot` |
  | 3 | racine | `IMAGE_ROOT_GIB` (agrandie au déploiement) | ext4 | `nomade-root` |
- E-07 `/etc/fstab` par UUID ; racine montée avec
  `noatime,lazytime,commit=60,errors=remount-ro`.
- E-08 Fichier `/etc/nomade/expected.env` écrit au build (valeurs attendues par l'autotest :
  utilisateur, hostname, locale…) et `/etc/nomade/build-info` (date, version de l'outil `NOMADE_VERSION`, version ISO, commit git).

## 4. Démarrage

- E-09 **shim signé + GRUB signé** (`shim-signed`, `grub-efi-amd64-signed`) installés dans le
  **chemin amovible** `/EFI/BOOT/BOOTX64.EFI` (+ `grubx64.efi`, `mmx64.efi`), **sans aucune
  écriture NVRAM**. Réglages debconf persistants : `grub2/force_efi_extra_removable=true`,
  `grub2/update_nvram=false` (les mises à jour de GRUB doivent maintenir le chemin amovible).
  `EFI/BOOT/grubx64.efi` identique au `grubx64.efi` installé (jamais la variante CD `gcdx64`) ;
  **jamais** de `fbx64.efi` ni de `BOOTX64.CSV` dans `EFI/BOOT` (boucle de redémarrage), y compris
  après une mise à jour de `shim-signed` (crochet APT). (D-015)
  Sous Zorin/Ubuntu, `grub-install` n'a pas `--force-extra-removable` et les mises à jour ignorent
  `update_nvram` : `EFI/BOOT` est resynchronisé par un script appelé par le crochet APT (D-029) et
  `grub-install` est dévié vers une enveloppe qui impose `--no-nvram` (D-033).
- E-10 Démarre avec **Secure Boot activé** (clés Microsoft) **et** désactivé.
- E-11 Menu GRUB visible 3 s (`config/rootfs/etc/default/grub.d/60-nomade.cfg`) : sur une
  machine inconnue, il faut pouvoir choisir le mode de dépannage.
- E-41 os-prober désactivé (`GRUB_DISABLE_OS_PROBER=true`) : le menu ne liste jamais les systèmes
  de la VM de build ni ceux du PC hôte, et `update-grub` ne sonde pas ses disques. (D-026)
- E-43 Aucune écriture dans le firmware du PC hôte en dehors du démarrage lui-même :
  `secureboot-db.service` (db/dbx d'Ubuntu écrites par `sbkeysync` dans la NVRAM),
  `fwupd.service` et `fwupd-refresh.timer` (mises à jour de firmware du PC proposées par
  Logiciels) sont masqués. (D-042)
- E-12 initramfs générique : `MODULES=most`, modules `uas`, `usb_storage`, `xhci_pci` présents ;
  `RESUME=none` ; **pas d'hibernation**.
- E-13 **Aucun pilote graphique propriétaire** (pas de `nvidia-driver-*`) ; Mesa/nouveau.
- E-14 Microcodes **Intel et AMD** installés (machine hôte inconnue) ; `linux-firmware` complet.

## 5. Localisation et identité

- E-15 Locale `fr_BE.UTF-8` ; clavier `be` (console, X11/Wayland, sources d'entrée GNOME) ;
  fuseau `Europe/Brussels` ; paquets de langue français complets
  (`check-language-support -l fr` ne doit plus rien proposer).
- E-16 Horloge matérielle en **heure locale** (`LocalRTC=yes`) : la clé tourne souvent sur
  des PC Windows.
- E-17 Hostname `TARGET_HOSTNAME`. Utilisateur `TARGET_USER` (UID 1000, groupes standards du
  premier utilisateur Ubuntu dont `sudo`), **compte verrouillé dans l'image** : le mot de passe
  est défini au déploiement.
- E-18 Pas de serveur SSH dans le système cible.

## 6. Réactivité et longévité

- E-19 `config/rootfs/etc/sysctl.d/60-nomade.conf` : écritures regroupées en RAM
  (`dirty_*`), `swappiness=180`, `page-cluster=0` (adaptés à zram).
- E-20 **zram** = 50 % de la RAM, zstd, priorité 100 (`systemd-zram-generator`, à défaut
  `zram-tools`) ; **aucun** fichier ni partition d'échange.
- E-21 `/tmp` en tmpfs.
- E-22 journald **persistant** plafonné à 200 Mo (diagnostic sur matériel inconnu).
- E-23 dpkg en `force-unsafe-io` (la clé n'est jamais arrachée).
- E-24 `fstrim.timer` actif.
- E-25 `profile-sync-daemon` activé globalement pour les sessions utilisateur, avec une
  définition pour **Brave**, le navigateur de Zorin 18.1 (Zorin ne livre pas Firefox, et psd 6.50
  ne connaît pas Brave) : profil `~/.config/BraveSoftware/Brave-Browser` en RAM. (D-021)
  `/run/user/<uid>`, où psd garde le profil, est plafonné à 25 % de la RAM
  (`logind.conf.d`, `RuntimeDirectorySize`) au lieu de 10 %. (D-040)
- E-26 GNOME : indexation de contenu (Tracker 3 / LocalSearch) **désactivée** sans casser la
  recherche par nom (noms de fichiers indexés, extraction du texte coupée : `max-bytes=0`) ;
  GNOME Logiciels ne télécharge pas les mises à jour en arrière-plan ;
  base dconf système `local` active (le profil `/etc/dconf/profile/user` doit l'inclure —
  fusionner avec l'existant s'il y en a un ; absent dans Zorin 18.1). (D-020)
- E-27 snapd retiré (vérifié en phase 0 : aucun snap installé par défaut), avec
  `gnome-software-plugin-snap`. (D-027)
- E-40 Services inutiles sur une clé nomade désactivés : `smartd`/`smartmontools`,
  `NetworkManager-wait-online`, `whoopsie`, `kerneloops`, `ModemManager`. Les mises à jour de
  sécurité automatiques (`unattended-upgrades`) restent actives. (D-022, D-024)

## 7. Déploiement sur la clé (réservé à Fabien, testé par Claude sur fichier)

`sudo make deploy KEY=/dev/disk/by-id/usb-…` exécute `scripts/deploy.sh` :

- E-28 **Garde-fous** : `assert_real_usb_target` (chemin `by-id/usb-*`, disque entier, transport
  USB, non monté, différent du disque système, affichage modèle/série/taille, **saisie du numéro
  de série** pour confirmer). En test : `assert_test_target` (fichier ou loop, `DEPLOY_TEST=1`).
- E-29 Écriture de l'image avec `bmaptool`, puis **agrandissement** de la racine pour remplir la
  clé, moins la partition exFAT `NOMADE-DATA` en fin de clé (E-44).
- E-44 `NOMADE-DATA` créée par défaut : `DEPLOY_DATA_PCT` % de la clé (10), au moins
  `DEPLOY_DATA_MIN_GIB` (8 Gio), aucune si la racine passait sous `IMAGE_ROOT_GIB` + 16 Gio ;
  `DEPLOY_DATA_GIB` impose une taille (`0` : aucune). Montée par `fstab` (UUID, `nofail`) sur
  `/media/NOMADE-DATA`, propriété de `TARGET_USER`, inscriptible sans mot de passe ; `exfatprogs` dans
  l'image. (D-046)
- E-30 Si `DEPLOY_ENCRYPT=1` (défaut) : racine en **LUKS2** dont la clé de volume est générée
  **sur la cible** (chiffrement en place ou recréation, au choix, à documenter) ; phrase de passe
  saisie par Fabien ; `discard` dans `crypttab` ; drapeaux persistants
  `--perf-no_read_workqueue --perf-no_write_workqueue --allow-discards` ; /boot reste en clair.
  La phrase de passe se tape en **clavier belge** dès l'initramfs (`KEYMAP=y`).
  La racine recréée compte un inode pour `DEPLOY_INODE_RATIO` octets (64 Kio), pas 16 Kio. (D-041)
- E-31 Mot de passe de `TARGET_USER` saisi au déploiement.
- E-32 Détection du pont USB de la clé (VID:PID) et écriture dans la cible de
  `/etc/udev/rules.d/60-nomade-usb.rules` à partir de `config/templates/60-nomade-usb.rules.in` :
  `rotational=0`, ordonnanceur `mq-deadline`, autosuspend désactivé, et `provisioning_mode=unmap`
  **uniquement si** un essai de discard réussit pendant le déploiement.
- E-33 Régénération en chroot de l'initramfs et de la config GRUB (UUID finaux, crypttab), contrôle
  final (fsck, présence du chemin amovible), puis affichage de la checklist du premier démarrage.
- E-34 Rejouable : relancer le déploiement sur la même clé repart proprement de zéro.

## 7 bis. Diagnostics (D-047 à D-049, `docs/diagnostic.md`)

- E-45 `make diag-cle KEY=…`, sur l'hôte, avant le déploiement, séparé de `deploy` : identification
  sans root ; avec root, SMART (si `smartctl`) et lectures directes, **sans rien écrire**
  (`assert_usb_disk`) ; `COMPLET=1` : analyse complète qui efface la clé (capacité réelle, TRIM réel,
  écritures aléatoires et synchronisées, écriture longue de `DUREE` min, remise à vide), derrière
  `assert_real_usb_target`. Verdict A à D et alertes. Essayé dans la VM de build seulement
  (`make diag-cle-test` : fichier inchangé en lecture seule, contrefaçon simulée détectée).
- E-46 `nomade-diag`, sur la clé déployée (lanceur « Diagnostic de la clé » dans le menu) : versions et
  autotest sur matériel réel (`selftest.sh --materiel`), PC, firmware et Secure Boot (CA Microsoft dans
  db), affichage, périphériques, la clé sur ce PC, démarrage, mémoire, écritures, erreurs ; mesures en
  option, écritures plafonnées à 1 Gio. Rien n'est modifié sur le PC.
- E-47 Rapports anonymisés par défaut (liste blanche pour `resume.json`, nettoyage des fichiers bruts,
  empreintes HMAC salées par le sel de l'hôte, contrôle final avant écriture), archive
  `.tar.zst` avec `resume.json` au schéma versionné ; `make diag-rapport` les rassemble dans
  `docs/terrain.md`.

## 8. Tests

- E-35 `make test` : démarrage de `out/latest.img` dans QEMU sur l'hôte (KVM, OVMF,
  clé simulée en USB sur `qemu-xhci`, NVRAM vierge), **Secure Boot activé puis désactivé**.
  L'autotest embarqué (`nomade-selftest.service`) ne s'exécute que dans une VM signalée par
  `fw_cfg` (`opt/nomade/selftest`) et écrit ses résultats sur le port série
  (`NOMADE-SELFTEST: PASS|FAIL …`, puis `RESULT=PASS|FAIL`). Le harnais prend une capture d'écran.
- E-36 L'autotest couvre au minimum les exigences E-02, E-07, E-09, E-10, E-12 à E-27,
  E-39 à E-41, E-43, E-44, E-46 et E-47. Toute exigence vérifiable automatiquement doit y avoir une ligne.
- E-37 `make deploy-test` : déploiement complet (chiffré) dans la VM de build vers un fichier
  creux de 64 Gio, puis démarrage de ce fichier dans QEMU sur l'hôte avec déverrouillage
  automatisé **propre au test** (aucune trace dans un système réellement déployé) : phrase tapée
  au clavier virtuel une fois la question visible.
- E-42 CI GitHub Actions : lint à chaque push ; construction complète + `make test` (Secure Boot
  on/off) sur les changements de scripts/configuration et à la demande ; diagnostic (journaux,
  série, capture) en artefact, pas l'image. (D-023)
- E-38 Reproductibilité : `make builder-destroy && make all` depuis un dépôt propre aboutit.

## 9. Hors périmètre

- Démarrage BIOS hérité (non UEFI).
- Pilotes propriétaires, édition Pro, édition Lite.
- Toute action sur l'hôte nécessitant root (installée par Fabien, voir README).
