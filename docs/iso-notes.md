# Notes sur l'ISO Zorin OS 18.1 Core (phase 0)

Inspection faite le 2026-11-07 dans la VM de build (ISO montée en loop, squashfs décompressé
dans `/work/inspect/rootfs`, requêtes `dpkg-query --admindir`, simulation APT en chroot).
Journal de la simulation : `out/logs/phase0-apt-sim.log` (non versionné).

## 1. Identité de l'ISO

| | |
|---|---|
| Fichier | `Zorin-OS-18.1-Core-64-bit.iso`, 3 909 091 328 octets, daté du 2026-04-14 |
| SHA-256 | `44649b97bd307fc4c8529205d098ebbf98575a1e1ba2ee7d7005b697af1721d5` |
| Source de l'empreinte | page d'aide Zorin « Correct SHA256 checksums » (voir `config/iso.env`), identique au `SHA256SUMS.txt` du miroir kernel.org |
| `.disk/info` | `Zorin-OS 18.1 Core 64bit` (`cd_type` = `dvd/single`) |
| Base | Ubuntu 24.04 « noble » (`VERSION_CODENAME=noble`), GNOME 46 |
| Plus récent ? | Non : sur le miroir, après 18.1 (avril 2026) il n'y a rien (pas de 18.2 ni de révision `r2` de 18.1). |

Temps mesurés : téléchargement 7 min 30 (≈ 8 Mo/s), copie dans la VM 22 s, `unsquashfs` 27 s.

## 2. Organisation (schéma Ubiquity, couche unique)

```
casper/filesystem.squashfs       2,99 Go compressé → 7,0 Gio (filesystem.size = 7 495 688 192)
casper/filesystem.manifest       2 030 paquets (système live complet)
casper/filesystem.manifest-remove  255 paquets à retirer après installation
casper/flatpak.manifest          16 runtimes flatpak (thèmes GTK Zorin), déjà dans le squashfs
casper/vmlinuz, initrd.zstd      noyau/initrd du live (6.17.0-20)
pool/ + dists/noble              dépôt hors ligne (voir § 4)
efi/boot/{bootx64,grubx64,mmx64,bootia32}.efi, boot/grub/   démarrage du live
```

- **Une seule couche** : pas de `minimal.standard.live.squashfs` empilés ni d'`install-sources.yaml`
  (schéma Subiquity d'Ubuntu 24.04) : Zorin garde Ubiquity. E-03 = décompresser
  `filesystem.squashfs`, puis faire en chroot ce que fait Ubiquity.
- Ligne de commande du live : `maybe-ubiquity quiet splash` (+ `nomodeset`, ou `nvidia-zorin` qui fait
  installer le pilote NVIDIA 580 par le crochet `42nvidia_zorin` : **à ne pas reproduire**, E-13).

## 3. Ce que fait Ubiquity après la copie (`/usr/share/ubiquity/plugininstall.py`)

Ordre : réseau → locale → apt → crochets `target-config` → **paquets de langue** → noyaux inutiles →
matériel (pilotes) → extras → MOK / **chargeur** → **`remove_extras`** → codecs → copie
réseau/bluetooth → cache apparmor → cache du fond d'écran → journaux.

`remove_extras` : `à retirer = manifest-remove − (paquets installés pendant l'installation
+ leurs dépendances)`. En EFI, il installe (donc garde) `grub-efi-amd64`, `grub-efi-amd64-signed`,
`shim-signed`, `mokutil` ; il garde les paquets de langue choisis ; la case « census » décochée ajoute
`zorin-os-census` à la liste. Purge simple, puis purge récursive.

Crochets `target-config` : xconfig, accessibilité, `31ubuntu_driver_packages`,
`40install_driver_updates`, `42nvidia_zorin` (pilotes propriétaires) : aucun à reproduire.

**Recette retenue pour E-02/E-03** (validée par simulation, § 7) :
1. `apt-get update`, puis en **une** transaction (`--purge --auto-remove`) :
   installer `grub-efi-amd64 grub-efi-amd64-signed shim-signed mokutil systemd-zram-generator
   profile-sync-daemon`, retirer `manifest-remove − LISTE_A_GARDER`, `snapd`,
   `gnome-software-plugin-snap`, `zorin-os-census`.
2. `LISTE_A_GARDER` (29 paquets du manifeste, à mettre dans `config/`) : chargeur
   (`grub-efi-amd64-bin grub-efi-amd64-signed shim-signed mokutil`), chiffrement pour le déploiement
   (`cryptsetup cryptsetup-bin cryptsetup-initramfs keyutils`), français (`language-pack-fr(-base)`,
   `language-pack-gnome-fr(-base)`, `hunspell-fr`, `hunspell-fr-classical`, `hyphen-fr`, `mythes-fr`,
   `libreoffice-l10n-fr`, `libreoffice-help-fr`, `libreoffice-help-common`, `gnome-user-docs-fr`,
   `wfrench`) et anglais de repli (`language-pack-en(-base)`, `language-pack-gnome-en(-base)`,
   `libreoffice-help-en-us`).
3. `apt-get full-upgrade`, puis purge des anciens noyaux (`apt-get autoremove --purge` : dans le
   chroot, `uname -r` est celui de la VM, donc 6.17.0-20 est bien retiré).

## 4. Où sont les paquets

| Paquet(s) | Où |
|---|---|
| `shim-signed` 1.58+15.8, `grub-efi-amd64-signed` 1.202.5+2.12-1ubuntu7.3, `grub-efi-amd64-bin`, `mokutil` | **squashfs** (mais dans `manifest-remove`) |
| `grub-efi-amd64` (porte les questions debconf `grub2/force_efi_extra_removable` et `grub2/update_nvram`) | **réseau** uniquement (ni squashfs ni pool) ; son installation retire `grub-pc`, `grub-pc-bin`, `grub-gfxpayload-lists` (BIOS, hors périmètre) |
| Paquets de langue français (et 10 autres langues) | **squashfs** (dans `manifest-remove`) ; `check-language-support -l fr` ne propose rien |
| `intel-microcode`, `amd64-microcode`, `linux-firmware`, `firmware-sof-signed` | **squashfs**, conservés (E-14 déjà satisfait) |
| Pilotes NVIDIA 580, ZFS, `dkms`, `build-essential`, `broadcom-sta-dkms`, `rtl8812au-dkms`, `grub-efi-ia32`, noyau 6.17.0-20 | **pool** de l'ISO (installation hors ligne optionnelle) : non utilisé |
| `systemd-zram-generator` 1.1.2, `profile-sync-daemon` 6.50 | **réseau**, `noble/universe` |

## 5. Contenu du squashfs (constats utiles)

- **Noyau** : `linux-generic-hwe-24.04` → 6.17.0-20 ; après `full-upgrade` : **7.0.0-42**
  (même noyau que l'hôte de Fabien). `/boot` contient aussi memtest86+ (désactivé dans le menu).
- **initramfs-tools** 0.142ubuntu25.8 : `MODULES=most` et `COMPRESS=zstd` **déjà** par défaut,
  `conf.d/splash` (`FRAMEBUFFER=y`). Initrd de 86 Mo (plymouth copie pilotes et firmwares graphiques).
  Hooks présents : casper (part avec le paquet), cryptroot, lvm2, mdadm, plymouth…
- **Chargeur** : `grub-pc` (BIOS) installé, pas `grub-efi-amd64`. `grub-common`/`grub-pc` sont des
  versions **Zorin** (`2.12-1ubuntu7.3+zorin2`), `grub-efi-amd64(-bin|-signed)` celles d'Ubuntu. Thème
  `grub-theme-zorin`. `efibootmgr` installé mais retiré par le manifeste (tant mieux : E-09).
- **EFI** : `/usr/lib/shim/{shimx64.efi.signed.latest, mmx64.efi, fbx64.efi}` ;
  `/usr/lib/grub/x86_64-efi-signed/{grubx64,gcdx64,grubnetx64}.efi.signed`. `gcdx64` est la variante
  « CD » : dans `EFI/BOOT`, elle mène à l'invite `grub>` (leçon Debian, § 8).
- **`/etc/default/grub`** : `GRUB_TIMEOUT_STYLE=hidden`, `GRUB_TIMEOUT=0`, `quiet splash`,
  `GRUB_THEME=…/zorin/theme.txt`, `GRUB_DISABLE_MEMTEST=true`. Aucun `grub.d/`.
  **`GRUB_DISABLE_OS_PROBER` absent** ; or le `30_os-prober` d'Ubuntu **exécute os-prober** sauf si la
  variable vaut `true` ou `auto` → à forcer à `true` (sinon : au build, le menu listerait l'Ubuntu de la
  VM ; sur la clé, chaque `update-grub` sonderait les disques du PC hôte). Fait dans
  `config/rootfs/etc/default/grub.d/60-nomade.cfg`.
- **snapd** 2.73 installé (+ `gnome-software-plugin-snap`), **aucun snap** (ni seed ni
  `/var/lib/snapd/snaps/*.snap`) → E-27 : snapd retiré.
- **Flatpak** 1.14.6 installé, Flathub configuré, 16 runtimes de thèmes GTK Zorin (13 Mo) : gardé.
- **Navigateur** : **Brave** 1.89 (dépôt `brave-browser-apt-release.s3.brave.com`, paquets
  `brave-browser`, `brave-keyring`, `zorin-os-www-browser`) ; **pas de Firefox**. Profil :
  `~/.config/BraveSoftware/Brave-Browser`, processus `/opt/brave.com/brave/brave`.
  `/etc/apt/preferences.d/mozilla` épingle `packages.mozilla.org` (priorité 1000) sans source active.
- **psd** 6.50 : définitions dans `/usr/share/psd/browsers/` (chromium, firefox, vivaldi…), **pas de
  Brave** → ajouter `config/rootfs/usr/share/psd/browsers/brave` :
  `DIRArr[0]="$XDG_CONFIG_HOME/BraveSoftware/Brave-Browser"` et `PSNAME="brave"` (D-021).
- **dconf** : seul profil `/etc/dconf/profile/ibus` ; **pas de `/etc/dconf/profile/user`** → à créer
  (`user-db:user` + `system-db:local`) ; rien à fusionner. Réglages Zorin par défaut dans les
  surcharges de schémas (`25_zorin-os-default-settings.gschema.override`, etc.).
- **Indexation** : **Tracker 3.7** (`tracker-miner-fs`, `tracker-extract`, pas encore LocalSearch).
  Schémas `org.freedesktop.Tracker3.Miner.Files` (`/org/freedesktop/tracker/miner/files/`) et
  `org.freedesktop.Tracker3.Extract` (`/org/freedesktop/tracker/extract/`, clés `max-bytes`,
  `text-allowlist`, `wait-for-miner-fs`). L'extracteur n'a plus d'unité systemd propre (lancé par
  miner-fs). L'overlay d'origine coupait **tout** (dossiers vides, `crawling-interval=-2`) et donc
  aussi la recherche par nom de la vue d'ensemble → corrigé : noms indexés (défauts), contenu non
  (`max-bytes=0`, `text-allowlist=[]`) (D-020).
- **GNOME Logiciels** 46 (version Zorin) : clés `download-updates`, `download-updates-notify`,
  `allow-updates` ; la surcharge Zorin met déjà `download-updates-notify=false`.
- **Mises à jour automatiques** : `20auto-upgrades` (`Unattended-Upgrade "1"`), timers `apt-daily*`,
  `update-notifier-download`, `fwupd-refresh` actifs → conservés (décision de Fabien, D-022).
- **Services actifs notables** : `ModemManager`, `smartd`/`smartmontools`, `whoopsie` (+ `.path`),
  `kerneloops`, `NetworkManager-wait-online`, `sssd`, `sysstat`, `ufw`, `thermald`, `cups*`,
  `systemd-oomd`, `systemd-timesyncd` (utile avec la RTC locale). Fabien fait désactiver les quatre
  premiers groupes (D-024).
- **Localisation** : seule `C.utf8` compilée ; `/etc/default/locale` vide ; clavier `us` ;
  fuseau `Etc/UTC` ; pas d'`/etc/adjtime`.
- **Identité** : hostname `zorin`, `/etc/hosts` sans `127.0.1.1`, `machine-id` vide (bien),
  aucun compte ≥ 1000 (l'utilisateur live est créé au démarrage par casper), `/etc/fstab` vide.
- **Groupes du premier utilisateur** (`passwd/user-default-groups`) : `adm cdrom dip lpadmin plugdev
  sambashare debian-tor libvirtd users` (filtrés sur les groupes existants : `debian-tor`, `libvirtd`
  absents) + `sudo` ajouté par user-setup.
- **sysctl** : aucun réglage `dirty_*`/`swappiness` existant (`10-*` Ubuntu, `20-apparmor-zorin`,
  `30-brave` vide, `30-tracker` = `max_user_watches`) → `60-nomade.conf` sans conflit.
- **journald** : `/var/log/journal` existe déjà (persistant par défaut) ; pas de `journald.conf.d/`.
- **`/tmp`** : `tmp.mount` fourni dans `/usr/share/systemd/tmp.mount`, non activé → le copier dans
  `/etc/systemd/system/` puis `systemctl enable tmp.mount` (E-21).
- `fstrim.timer` **déjà actif** (E-24). Pas de `openssh-server` (E-18). Pas de swap ni de zram.
- `/etc/dpkg/dpkg.cfg.d/` vide, `/etc/udev/rules.d/` vide, pas de `zram-generator.conf`.
- Autres paquets « live » du manifeste : `casper`, `ubiquity*`, `user-setup`, `boot-repair`,
  `boot-sav*`, `apparmor-zorin-live`, `nvidia-zorin-live`, `zorin-os-census-live`, `gparted`, `efibootmgr`.
- `zorin-gnome-tour-autostart` lance la visite Zorin à la première session : gardé (pas d'effet sur
  l'écran de connexion GDM attendu par le test).

## 6. Dépôts APT (conservés, E-04)

`/etc/apt/sources.list` : archive Ubuntu `noble`, `noble-updates`, `noble-security`
(`main restricted universe multiverse`). `sources.list.d/` : `zorin.list`
(`packages.zorinos.com/{stable,patches,apps,drivers}`), quatre PPA Launchpad Zorin (deb822, clé en
ligne), `brave-browser-release.list`. Épinglages : `zorin-os-patches.pref` et
`zorinos-patches.pref` (999), `mozilla` (1000). `99never-include-phased-updates`.
Listes APT vides dans le squashfs : `apt-get update` obligatoire.

## 7. Simulation APT en chroot (2026-11-07)

- Purge : 226 paquets du manifeste (29 gardés) + `snapd`, `gnome-software-plugin-snap`, `grub-pc`,
  `grub-pc-bin`, `grub-gfxpayload-lists` = 231 purges, **aucune cascade** d'`--auto-remove`.
- Installations : `grub-efi-amd64` 2.12-1ubuntu7.3, `systemd-zram-generator` 1.1.2-3,
  `profile-sync-daemon` 6.50-1.
- `full-upgrade` : 572 mis à jour, 49 nouveaux, **≈ 1,7 Go** à télécharger, noyau 7.0.0-42.
  → cache APT hors de l'image (leçon Debian), dans la VM (`/work/cache/apt`), perdu seulement avec
  `builder-destroy`.

## 8. Pièges (constatés ici ou repris de `reference/debian/docs/lecons.md`)

- **`/etc/resolv.conf` est un lien** vers `../run/systemd/resolve/stub-resolv.conf` : avec un `/run`
  en tmpfs vide, pas de DNS dans le chroot. Écrire `run/systemd/resolve/stub-resolv.conf` (et ne pas
  remplacer le lien).
- **`fbx64.efi` ou `BOOTX64.CSV` dans `EFI/BOOT` = boucle de redémarrage** (shim tente d'écrire la
  NVRAM puis redémarre) : crochet APT `DPkg::Post-Invoke` qui les supprime, comme dans le projet Debian.
- **`EFI/BOOT/grubx64.efi` doit être identique à `EFI/ubuntu/grubx64.efi`** (pas `gcdx64`), avec un
  `grub.cfg` qui trouve `/boot` : contrôle `cmp` au build et ligne d'autotest.
- Jamais de NVRAM : `grub-install --no-nvram`, debconf `update_nvram=false`, `efibootmgr` retiré.
- Montages du build dans un espace de noms privé (`unshare --mount --propagation private`) ; tuer les
  processus restés dans le chroot avant de démonter ; `policy-rc.d` (exit 101) pendant le build ;
  `-o Dpkg::Options::=--force-confold`.
- Cache APT monté depuis l'extérieur de l'image ; en fin de build `e2fsck -f -E discard` des ext4
  démontés (blocs libres rendus au fichier, de façon reproductible) et `fstrim` de l'ESP.
- `lsblk -dno PKNAME` (sans `-d`, les enfants dm-* sont listés aussi) ; `realpath -m`.
- `systemctl is-system-running --wait` dans l'autotest : l'essai doit s'éteindre seul même en échec.
- Déploiement chiffré : `KEYMAP=y` dans l'initramfs (sinon la phrase LUKS se tape en QWERTY) ;
  option `initramfs` dans `crypttab` quand on régénère depuis un chroot ; avec `pipefail`, lire
  `cryptsetup luksDump` dans une variable plutôt que `| grep -q` ; `cryptsetup reencrypt --batch-mode`
  n'affiche aucune progression (`--progress-json` si besoin) ; chiffrer **avant** d'agrandir.
- Règle udev : la règle Debian est en `61-` car elle lit `ID_BUS` (posé par `60-persistent-storage`).
  La nôtre ne lit que `ATTRS{idVendor}`/`ATTRS{idProduct}` : `60-nomade-usb.rules` convient.
- Pont SSK `090c:2320` : instable en UAS sur le portable HP de Fabien **pendant mkfs** (vu côté hôte) ;
  en UAS le TRIM marche. À surveiller au premier démarrage natif (`journalctl -k | grep uas_eh`).
