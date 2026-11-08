# Premier démarrage d'une clé déployée

Checklist à dérouler après `sudo make deploy`, sur un vrai PC. Idéalement : **un PC avec Secure Boot
actif et un PC sans**. Les commandes s'exécutent sur la clé, dans un terminal (Ctrl+Alt+T) ; celles qui
commencent par `sudo` demandent ton mot de passe. Référence : clé SSK (pont `090c:2320`) sur
HP ProBook 455 G10, 2026-11-08 (valeurs mesurées entre parenthèses).

## Démarrage

- [ ] Clé sur un port USB 3, menu de démarrage du firmware (F12, F9, F8, Échap selon le PC) → entrée
      USB/UEFI de la clé. Rien à ajouter dans le firmware.
- [ ] Menu GRUB visible 3 s (entrées « Zorin OS » et options avancées).
- [ ] Question LUKS : la phrase se tape en clavier belge ; l'indicateur affiche `be`.
- [ ] Écran de connexion, session GNOME ouverte avec ton mot de passe.
- [ ] `mokutil --sb-state` → l'état attendu selon le PC.
- [ ] Secure Boot activé et clé refusée : activer l'option du firmware qui autorise « Microsoft UEFI CA »
      (PC « Secured-core », voir `README.md`, Dépannage), ou désactiver Secure Boot.
- [ ] Clé débranchée, le menu de démarrage du firmware **ne garde aucune entrée « ubuntu » ou
      « Zorin »** : la clé n'écrit jamais en NVRAM, seule l'entrée USB générique du firmware apparaît
      quand elle est branchée.
- [ ] `systemd-analyze` → durée de démarrage, pour comparer d'un PC à l'autre (≈ 40 s, dont ≈ 12 s de
      firmware HP et le temps de taper la phrase).

## Matériel

- [ ] Wi-Fi (connexion à un réseau), son (haut-parleurs, prise casque), écran (résolution, second écran).
- [ ] `lsusb -t` → le pont de la clé utilise le pilote **`uas`** (`Driver=uas`) à 5 ou 10 Gbit/s.
- [ ] `journalctl -k | grep -i uas_eh` → **rien**. Sinon : réinitialisations UAS du pont ; contournement
      `usb-storage.quirks=090c:2320:u` sur la ligne du noyau (perd UAS et TRIM).
- [ ] `cat /etc/nomade/deploy-info` → `DEPLOY_USB_ID` = VID:PID réel du pont, `DEPLOY_DISCARD=1` si le
      TRIM a été accepté au déploiement.
- [ ] Mise en veille : fermer le capot (ou attendre 15 min sur batterie), rouvrir, puis
      `journalctl -k -b | grep -iE 'uas|reset|I/O error'` → rien de neuf depuis la mise en veille.

## SSD et chiffrement

- [ ] `lsblk --discard` → `DISC-GRAN` et `DISC-MAX` non nuls pour `sdX`, `sdX3` et `nomade-root`.
- [ ] `cat /sys/block/sdX/queue/rotational` → `0` ; `cat /sys/block/sdX/queue/scheduler` →
      `[mq-deadline]`.
- [ ] `sudo fstrim -v /` → une quantité réduite. Au premier passage après un démarrage, ext4 annonce
      tout l'espace libre (927,7 Gio sur 1 To) : c'est normal.
- [ ] `sudo cryptsetup status nomade-root` → `flags: discards no_read_workqueue no_write_workqueue`.
- [ ] Les premières minutes après le **premier** démarrage, le disque travaille en tâche de fond
      (`ext4lazyinit` initialise les tables d'inodes) : une seule fois.

## Réglages

- [ ] `swapon` → seulement `/dev/zram0`, priorité 100 ; `findmnt /tmp` → `tmpfs`.
- [ ] Brave : le lancer une fois, se déconnecter puis se reconnecter, puis `psd p` → profil
      `Brave-Browser` en RAM ; `df -h /run/user/$(id -u)` → 25 % de la RAM.
- [ ] Recherche par nom : touche Super, taper le nom d'un fichier de `~/Documents` → il apparaît.
- [ ] Logiciels (GNOME) : pas de téléchargement en arrière-plan ; mises à jour de sécurité automatiques
      actives (`systemctl status unattended-upgrades`).
- [ ] `systemctl is-enabled secureboot-db fwupd fwupd-refresh.timer` → `masked` (trois fois).

## Première mise à jour

- [ ] `sudo apt update && sudo apt full-upgrade`, puis `sudo ls /boot/efi/EFI/BOOT` : `BOOTX64.EFI`,
      `grubx64.efi`, `mmx64.efi`, `grub.cfg`, et **ni `fbx64.efi` ni `BOOTX64.CSV`** ; redémarrer.

Tout écart (surtout `uas_eh`, Wi-Fi, TRIM, veille) se corrige dans `config/` ou les scripts, avec une
ligne d'autotest, et se consigne dans `docs/JOURNAL.md`.
