# Plan

Légende : `[ ]` à faire · `[x]` fait · `[!]` bloqué (raison dans `docs/JOURNAL.md`).
Chaque phase se termine par `make lint` propre et un commit. Les critères d'acceptation
sont **vérifiables** : une phase n'est terminée que lorsqu'ils passent.
Références constantes : `docs/iso-notes.md` (constats sur l'ISO, recette, pièges) et les décisions
D-013 à D-028.

## Phase 0 — État des lieux (interactive, effort xhigh)

- [x] Lire `CLAUDE.md`, `SPEC.md`, `DECISIONS.md`, `README.md`.
- [x] Initialiser git si nécessaire (commit initial de la base).
- [x] `make doctor` ; reporter dans `docs/A-FAIRE-FABIEN.md` ce qui manque sur l'hôte.
- [x] Parcourir `reference/debian` (si présent) : relever les conventions utiles (Makefile,
      VM de création, CI/CD, tests, journalisation) et les adopter quand elles conviennent
      (décisions dans `DECISIONS.md`). Ne rien y écrire.
- [x] Trouver la dernière ISO **Zorin OS 18.x Core** officielle et son SHA-256 publié par Zorin ;
      remplir `config/iso.env` (avec la source de l'empreinte). `make iso`.
- [x] `make builder` ; vérifier SSH, cloud-init, espace disque dans la VM.
- [x] Inspecter l'ISO dans la VM et consigner dans `docs/iso-notes.md`.
- [x] Ajuster les phases 1 à 5 ci-dessous selon ces constats.
- [x] **S'arrêter** et présenter à Fabien : constats, décisions, plan ajusté, points ouverts.

## Phase 1 — Image minimale qui démarre

Architecture (D-017) : `scripts/vm/*.sh` = scripts root autonomes (VM de build **ou** runner CI),
chemins en arguments ; `scripts/build-image.sh` (hôte) orchestre envoi → exécution → rapatriement.

- [x] `config/packages.env` (ou `config/packages/*.list`) : liste à garder du manifeste (29 paquets,
      `docs/iso-notes.md` § 3), paquets à ajouter (`grub-efi-amd64 grub-efi-amd64-signed shim-signed
      mokutil systemd-zram-generator profile-sync-daemon`), à retirer en plus (`snapd
      gnome-software-plugin-snap zorin-os-census`).
- [x] `scripts/build-image.sh` (hôte) : `make builder`, envoi du dépôt (scripts + config) et de
      l'ISO (si absente ou d'empreinte différente) dans `/work`, exécution de `scripts/vm/build.sh`
      sous `sudo`, journal `out/logs/build-<horodatage>.log`, rapatriement en préservant le creux.
- [x] `scripts/vm/build.sh` : tout dans `unshare --mount --propagation private`, nettoyage par
      `trap` (processus du chroot tués, démontages, `losetup -d`), idempotent (repart de zéro).
- [x] Image creuse `IMAGE_ESP_MIB + IMAGE_BOOT_MIB + IMAGE_ROOT_GIB`, GPT E-06 (`sgdisk`, types
      EF00/8300/8300, étiquettes), `mkfs.vfat -F 32 -n NOMADE-ESP`, `mkfs.ext4 -L nomade-boot/root`.
- [x] `unsquashfs` de `casper/filesystem.squashfs` directement dans la racine montée ; contenu de
      `/boot` déplacé sur p2 ; ESP sur `/boot/efi`.
- [x] Préparation du chroot : `/dev` (rbind, rslave), `/proc`, `/sys`, `/run` (tmpfs) avec
      **`run/systemd/resolve/stub-resolv.conf`** (lien `resolv.conf`, voir iso-notes § 8),
      `policy-rc.d` (101), cache APT lié depuis `/work/cache/apt` (hors image), debconf GRUB
      (`force_efi_extra_removable=true`, `update_nvram=false`) **avant** l'installation de GRUB,
      crochet APT `99-nomade-no-shim-fallback` (supprime `EFI/BOOT/fbx64.efi` et `BOOTX64.CSV`).
- [x] Transaction APT unique (D-014, D-025, D-027), journal de ce qui est purgé ; puis
      `full-upgrade` (≈ 1,7 Go la première fois, noyau 7.0) et `autoremove --purge` (ancien noyau) ;
      contrôle : aucun paquet live (`casper`, `ubiquity*`, `user-setup`, `*-zorin-live`) ni snapd.
- [x] Configuration : `fstab` par UUID (E-07), hostname + `127.0.1.1` (E-17), `/etc/adjtime`
      `LOCAL` (E-16), `locale-gen` + `update-locale LANG=fr_BE.UTF-8 LANGUAGE=fr_BE:fr`, clavier
      `be` (`/etc/default/keyboard`, `setupcon --save-only`), fuseau (E-15), utilisateur UID 1000,
      groupes `adm cdrom dip lpadmin plugdev sambashare users sudo` (filtrés sur l'existant),
      compte verrouillé (E-17), `machine-id` vide.
- [x] Copie de l'overlay `config/rootfs/` (sans écraser un fichier existant du squashfs sans
      fusion consignée), `/etc/nomade/expected.env` et `build-info` (E-08), activation de
      `nomade-selftest.service`.
- [x] initramfs (E-12) : `RESUME=none` (overlay ; `MODULES=most` déjà par défaut),
      `update-initramfs -u -k all` après la purge de casper.
- [x] GRUB (E-09, E-11, E-41, D-029) : `grub-install --target=x86_64-efi --efi-directory=/boot/efi
      --uefi-secure-boot --no-nvram` (Ubuntu : pas de `--force-extra-removable`, dossier
      `EFI/ubuntu` imposé par le GRUB signé), puis `efi-removable-sync.sh` (aussi crochet APT),
      `update-grub` ; contrôles bloquants : `BOOTX64.EFI` = shim,
      `EFI/BOOT/grubx64.efi` identique à `EFI/ubuntu/grubx64.efi`, `mmx64.efi` présent, pas de
      `fbx64.efi`/`BOOTX64.CSV`, `grub.cfg` atteignable depuis `EFI/BOOT`, aucune entrée `osprober`.
- [x] Nettoyage : `apt-get clean`, démontage du cache, `resolv`, `/tmp`, journaux ; `fstrim` de
      l'ESP ; démontage strict puis `e2fsck -f -p -E discard` des deux ext4 ; « blocs alloués » affiché.
- [x] Artefacts `out/` (E-05) : `.img`, `.bmap` (`bmaptool create`), `.manifest`, `.sha256`,
      lien `out/latest.img` ; rapatriement creux.
- [x] Mémoire (D-016) : `test-image.sh` vérifie la RAM disponible et arrête la VM de build si elle
      tourne et qu'il en manque.
- [x] **Acceptation** : `make test` → les deux essais (Secure Boot on/off) atteignent
      `graphical.target`, la capture montre l'écran de connexion GNOME.

## Phase 2 — Réglages et autotest complet

- [x] E-13 (aucun pilote NVIDIA : rien à installer, contrôler), E-14 (déjà dans le squashfs).
- [x] E-19 à E-24 : overlay sysctl, zram (`zram-generator.conf`), `tmp.mount` copié depuis
      `/usr/share/systemd/` puis activé, journald, dpkg `force-unsafe-io`, `fstrim.timer` (déjà actif).
- [x] E-25 (D-021) : `config/rootfs/usr/share/psd/browsers/brave`, `systemctl --global enable
      psd.service`.
- [x] E-26 (D-020) : créer `/etc/dconf/profile/user` (`user-db:user`, `system-db:local`), base
      `local` de l'overlay, `dconf update`.
- [x] E-40 (D-024) : `systemctl disable` de `smartd`, `smartmontools`, `NetworkManager-wait-online`,
      `whoopsie` (+ `whoopsie.path`), `kerneloops`, `ModemManager`. Constaté en phase 1 :
      `smartmontools` est déjà purgé par le manifeste (contrôle « absent ou désactivé »).
- [x] E-15 : `check-language-support -l fr` vide **après** la purge (installer ce qu'il propose) ;
      E-04 : manifeste `dpkg-query` livré (`out/*.manifest` et copie dans `/etc/nomade/`).
- [x] Autotest (`selftest.sh`) — lignes à ajouter : E-09 (pas de `fbx64.efi`/`BOOTX64.CSV`,
      `cmp` du `grubx64.efi` amovible, `mmx64.efi`, debconf `update_nvram=false`, `grub-install`
      dévié vers l'enveloppe `--no-nvram` (D-033), `EFI/ubuntu/grub.cfg` présent), E-25 (définition
      Brave, psd activé), E-26 (lecture `gsettings` avec `DCONF_PROFILE=user` et un `HOME` vide :
      `max-bytes=0`, `download-updates=false`), E-27 (snapd absent, pas de `/snap`), E-39 (census
      absent), E-40 (services désactivés), E-41 (`GRUB_DISABLE_OS_PROBER=true`, aucune entrée
      `osprober` dans `grub.cfg`), E-15 (`check-language-support -l fr` vide, `fr_BE.UTF-8`
      compilée), E-12 (initrd contient la disposition clavier si `KEYMAP=y`, après la phase 3).
- [x] **Acceptation** : `make test` → `RESULT=PASS` avec Secure Boot activé **et** désactivé.

## Phase 3 — Déploiement

- [x] `scripts/deploy.sh` selon E-28 à E-34 (garde-fous de `lib.sh` obligatoires) : secrets saisis
      d'abord, VID:PID du pont, essai de TRIM (D-036), effacement, `bmaptool copy`, `sgdisk -e`,
      agrandissement de p3 (moins `DEPLOY_DATA_GIB`), partition exFAT optionnelle ; si chiffrement :
      **recréation** (D-035, au lieu du chiffrement en place) — `blkdiscard` de p3, `luksFormat`
      LUKS2, ouverture `--persistent --perf-no_read_workqueue --perf-no_write_workqueue
      --allow-discards`, `mkfs.ext4` au même UUID, `rsync -aHAXS` depuis la racine de l'image ;
      sinon `resize2fs`.
- [x] Chroot de la cible : `crypttab` (`luks,discard,initramfs`), `fstab` inchangé (même UUID,
      D-035), `KEYMAP=y` déjà dans l'image (D-034), `update-initramfs`, `update-grub`, mot de passe de
      l'utilisateur (`chpasswd`), règle udev depuis le modèle (VID:PID détecté ; essai de discard
      pour `provisioning_mode=unmap`), contrôles finaux (fsck, chemin amovible), checklist affichée.
- [x] `scripts/deploy-test.sh` (E-37) : dans la VM, fichier creux de `DEPLOY_TEST_SIZE_GIB`,
      `DEPLOY_TEST=1`, VID:PID imposé à celui du `usb-storage` de QEMU (`46f4:0001`), phrase et mot
      de passe de test générés à l'exécution (jamais écrits dans la cible) ; rapatriement.
- [x] `scripts/test-image.sh --encrypted` : saisie de la phrase au clavier virtuel (QMP `send-key`)
      quand la question est visible à l'écran (disque inactif, D-037) ; touches d'un AZERTY (D-034) ; phrase composée de lettres identiques en AZERTY et
      QWERTY, plus un contrôle que l'initramfs embarque la disposition `be`.
- [x] **Acceptation** : `make deploy-test` → `RESULT=PASS`, racine sur `dm-crypt`,
      `crypttab` avec `discard`, drapeaux de performance LUKS persistants, utilisateur
      déverrouillé, règle udev générée (VID:PID du test).

## Phase 4 — CI (D-023)

- [x] `.github/workflows/lint.yml` : inchangé (lint à chaque push).
- [x] `.github/workflows/image.yml` : push sur `scripts/**`, `config/**`, `Makefile`, le workflow,
      et `workflow_dispatch` ; runner ubuntu-24.04 ; espace disque libéré ; outils installés ; accès
      KVM (règle udev, comme le projet Debian) ; ISO en `actions/cache` (clé = `ISO_SHA256`) ;
      `sudo scripts/vm/build.sh …` directement sur le runner ; `make test` en utilisateur ;
      artefacts de diagnostic (`out/logs/`, `out/test/*/serial.log`, `screen.png`, `summary.txt`) ;
      pas d'image en artefact.
- [x] Documenter dans `README.md` ce qui tourne en CI et ce qui reste local (déploiement).
- [x] `make ci` = lint + `scripts/test-guards.sh` (refus attendus des garde-fous, sans root).
- [x] **Acceptation** : `make ci` passe localement ; le workflow `image` est vert sur GitHub dès que
      Fabien a créé le dépôt et poussé (sinon noter dans `docs/A-FAIRE-FABIEN.md`).
      → `make ci` vert en local ; dépôt GitHub pas encore créé : marche à suivre dans
      `docs/A-FAIRE-FABIEN.md` (vérification du workflow `image` sur GitHub à faire par Fabien).

## Phase 5 — Reproductibilité et rapport

- [x] `make builder-destroy && make all` depuis un clone propre (E-38).
- [x] `docs/RAPPORT.md` : ce qui a été fait, déviations, limites connues, durée et taille
      des artefacts, **checklist du premier démarrage natif** pour Fabien (Wi-Fi, son,
      `lsusb -t` → `uas`, `lsblk --discard`, `fstrim -v /`, `swapon`, session GNOME, Brave + psd
      (`psd p`), recherche par nom, `journalctl -k | grep uas_eh` (pont SSK 090c:2320),
      démarrage sur un PC Secure Boot et un PC sans).
- [x] Mettre à jour `README.md` si l'usage a changé.

## Phase 6 — Retour d'expérience sur la clé déployée (2026-11-08)

Clé déployée le 2026-11-08 (image `zorin-nomade-20261108-1009`), évaluée en usage réel sur le HP de
Fabien (mesures et constats : `docs/JOURNAL.md`). Branche `correctifs-cle`, préparée **sur la clé**
(sans `make`, QEMU ni OVMF : lint par shellcheck seul) ; à valider sur l'hôte avant fusion.

- [x] Évaluation sur matériel réel : débits, latences, démarrage, mémoire, écritures, TRIM, services.
- [x] `deploy.sh` : essai de TRIM avec `blkdiscard -f </dev/null` et cause consignée (l'essai échouait
      sur toute clé déjà partitionnée quand stdin est un terminal) ; `deploy-test.sh` exige que l'essai
      réussisse à chaque passage.
- [x] D-041 : racine recréée avec `mkfs.ext4 -i $DEPLOY_INODE_RATIO` (64 Kio) ; contrôle d'autotest.
- [x] D-040 : `logind.conf.d/60-nomade.conf` (`RuntimeDirectorySize=25%`) ; contrôle d'autotest.
- [x] D-042 / E-43 : `secureboot-db.service`, `fwupd.service`, `fwupd-refresh.timer` masqués au build ;
      contrôles d'autotest.
- [x] README § 5 (Secure Boot et PC « Secured-core ») ; checklist du rapport (veille, option MS UEFI CA).
- [x] Correctifs à chaud sur la clé (D-040, D-042, règle udev `provisioning_mode=unmap`,
      `DEPLOY_DISCARD=1`) ; GNOME Logiciels sans lancement automatique (`~/.config/autostart`).
      Vérifiés après redémarrage : unités masquées, `/run/user/1000` à 1,8 Gio, Logiciels absent.
- [ ] Pousser la branche dès que GitHub répond — **avant tout redéploiement** (il efface la clé,
      `/home` et ce clone compris).
- [ ] Sur l'hôte : `make lint`, `make ci`, `make image`, `make test`, `make deploy-test` ; vérifier les
      nouvelles lignes (E-25, E-30, E-43) et « TRIM : essai réussi » aux deux passages ; fusionner
      dans `main`.
- [ ] Image : GNOME Logiciels sans service résident, sans écraser `/etc/xdg/autostart` du squashfs
      (méthode à choisir et à consigner).
- [ ] Facultatif : initramfs sans pilotes réseau de serveur ni leurs firmwares (≈ 30 Mo sur 83,
      ≈ 1 s de GRUB) ; rsyslog et avahi à couper (gains marginaux).
