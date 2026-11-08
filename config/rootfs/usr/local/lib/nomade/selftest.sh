#!/usr/bin/env bash
# zorin-nomade — autotest de l'image (SPEC E-35, E-36).
#
# Ne s'exécute que dans une VM QEMU lancée par scripts/test-image.sh, qui expose via fw_cfg :
#   opt/nomade/selftest = 1        active l'autotest
#   opt/nomade/expect_sb = on|off  état Secure Boot attendu
#   opt/nomade/poweroff = 1        éteint la VM après le rapport
# Résultats sur le port série (/dev/ttyS0) et dans le journal :
#   NOMADE-SELFTEST: PASS|FAIL <exigence> <libellé>
#   NOMADE-SELFTEST: RESULT=PASS | RESULT=FAIL (n)
#
# Ajoute une ligne « check » pour chaque exigence vérifiable de SPEC.md.
set -u

FW=/sys/firmware/qemu_fw_cfg/by_name/opt/nomade
modprobe qemu_fw_cfg 2>/dev/null || true
for _ in 1 2 3 4 5; do [[ -r $FW/selftest/raw ]] && break; sleep 1; done
[[ -r $FW/selftest/raw ]] || exit 0

fwval() { cat "$FW/$1/raw" 2>/dev/null || true; }

# Valeurs attendues (écrites au build, SPEC E-08), avec des valeurs par défaut.
TARGET_HOSTNAME=zorin-nomade TARGET_USER=fabien TARGET_LOCALE=fr_BE.UTF-8
TARGET_KEYMAP=be TARGET_TIMEZONE=Europe/Brussels
# shellcheck disable=SC1091
[[ -r /etc/nomade/expected.env ]] && source /etc/nomade/expected.env

SERIAL=/dev/ttyS0
say() {
  printf 'NOMADE-SELFTEST: %s\n' "$*" >>"$SERIAL" 2>/dev/null || true
  printf 'NOMADE-SELFTEST: %s\n' "$*"
}

FAILS=0
# check <exigence> <libellé> <commande…>
check() {
  local req="$1" label="$2"; shift 2
  if "$@" >/dev/null 2>&1; then say "PASS $req $label"
  else say "FAIL $req $label"; FAILS=$((FAILS + 1)); fi
}

# --- Aides ---------------------------------------------------------------------
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }
pkg_absent() { ! pkg_installed "$1"; }
any_pkg_installed() { local p; for p in "$@"; do pkg_installed "$p" && return 0; done; return 1; }
no_pkg_matching() { ! dpkg-query -W -f='${Package} ${Status}\n' "$1" 2>/dev/null | grep -q 'install ok installed'; }
sysctl_is() { [[ "$(sysctl -n "$1" 2>/dev/null)" == "$2" ]]; }
root_has_opt() { findmnt -no OPTIONS / | tr ',' '\n' | grep -qx "$1"; }
fstype_is() { [[ "$(findmnt -no FSTYPE "$1" 2>/dev/null)" == "$2" ]]; }
only_zram_swap() {
  swapon --noheadings --show=NAME | grep -q zram || return 1
  ! swapon --noheadings --show=NAME | grep -vq zram
}
# Module disponible dès l'initramfs : présent dans l'initramfs ou intégré au noyau.
early_module() {
  grep -q "/$1\.ko" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null && return 0
  lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -q "/$1\.ko"
}
# shellcheck disable=SC2086
conf_has() { grep -Eqs "$2" $1; }   # $1 : motif de fichiers, non quoté exprès
timedate_is() { [[ "$(timedatectl show -p "$1" --value 2>/dev/null)" == "$2" ]]; }
user_locked() { [[ "$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{ print $2 }')" == L ]]; }
sb_state() {
  local files=(/sys/firmware/efi/efivars/SecureBoot-*)
  [[ -d /sys/firmware/efi/efivars ]] || { echo unknown; return; }
  # Variable absente : firmware sans Secure Boot (OVMF non « secboot »), donc désactivé.
  [[ -e "${files[0]}" ]] || { echo off; return; }
  if [[ "$(od -An -t u1 -j4 -N1 "${files[0]}" | tr -d ' ')" == 1 ]]; then echo on; else echo off; fi
}
# Unité désactivée (ou absente) et inactive (E-40). « static » est admis : une telle unité ne
# démarre que par un déclencheur (whoopsie.service ← whoopsie.path, lui-même désactivé).
unit_off() {
  local st
  st="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  [[ "$st" != enabled* && "$st" != alias && "$st" != indirect ]] || return 1
  ! systemctl is-active --quiet "$1"
}
# Lecture GSettings comme une session neuve : profil « user », aucun réglage personnel (E-26)
gs_is() {
  local h v
  h="$(mktemp -d)"
  v="$(env -i HOME="$h" XDG_CONFIG_HOME="$h/.config" DCONF_PROFILE=user PATH="$PATH" \
         gsettings get "$1" "$2" 2>/dev/null || true)"
  rm -rf "$h"
  [[ "$v" == "$3" ]]
}
gs_not() { ! gs_is "$@"; }
ESP=/boot/efi/EFI
same_file() { cmp -s "$1" "$2"; }
no_fallback() { [[ ! -e $ESP/BOOT/fbx64.efi && ! -e $ESP/BOOT/BOOTX64.CSV ]]; }
debconf_is() { debconf-show "$1" 2>/dev/null | grep -Eq "^[* ] $2: $3\$"; }
grub_install_wrapped() {
  [[ "$(readlink /usr/sbin/grub-install)" == /usr/local/lib/nomade/grub-install-no-nvram ]] \
    && dpkg-divert --list /usr/sbin/grub-install | grep -q 'grub-install.real'
}
zram_ok() {
  local mem disk
  grep -q '\[zstd\]' /sys/block/zram0/comp_algorithm || return 1
  mem="$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo)"
  disk="$(cat /sys/block/zram0/disksize)"
  # 50 % de la RAM, à 2 % près
  (( disk * 100 > mem * 48 && disk * 100 < mem * 52 ))
}
zram_prio() { swapon --noheadings --show=NAME,PRIO | awk '$1 ~ /zram/ { print $2 }' | grep -qx 100; }
lang_complete() { [[ -z "$(check-language-support -l "${TARGET_LOCALE%%_*}" 2>/dev/null)" ]]; }
locale_built() { locale -a 2>/dev/null | grep -qix "${TARGET_LOCALE/UTF-8/utf8}"; }
user_has_group() { id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$1"; }
initrd_has() { lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -q "$1"; }
journald_cap() { systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -qx 'SystemMaxUse=200M'; }
no_listen_ssh() { ! ss -Hltn 2>/dev/null | awk '{ print $4 }' | grep -qE ':22$'; }
user_unlocked() { [[ "$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{ print $2 }')" == P ]]; }
# Clé déployée : racine → mappeur → partition → disque USB
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null)"
ROOT_PART="$(lsblk -nrspo NAME,TYPE "$ROOT_SRC" 2>/dev/null | awk '$2 == "part" { print $1; exit }')"
ROOT_DISK="$(lsblk -ndo PKNAME "$ROOT_PART" 2>/dev/null)"
root_is_crypt() { [[ "$(lsblk -ndo TYPE "$ROOT_SRC" 2>/dev/null)" == crypt ]]; }
luks_is_v2() { cryptsetup luksDump "$ROOT_PART" 2>/dev/null | grep -Eq '^Version:[[:space:]]+2$'; }
luks_flags() {
  local f
  f="$(cryptsetup luksDump "$ROOT_PART" 2>/dev/null | awk -F: '/^Flags:/ { gsub(/[[:space:]]+/, " ", $2); print $2 }')"
  [[ " $f " == *" allow-discards "* && " $f " == *" no-read-workqueue "* && " $f " == *" no-write-workqueue "* ]]
}
dm_flags() {
  local f
  f="$(cryptsetup status "$ROOT_SRC" 2>/dev/null | awk -F: '/^ *flags:/ { gsub(/[[:space:]]+/, " ", $2); print $2 }')"
  [[ " $f " == *" discards "* && " $f " == *" no_read_workqueue "* && " $f " == *" no_write_workqueue "* ]]
}
boot_plain() { [[ "$(lsblk -ndo TYPE "$(findmnt -no SOURCE /boot)" 2>/dev/null)" == part ]]; }
crypttab_discard() { awk '$1 !~ /^#/ && NF >= 4 { print $4 }' /etc/crypttab 2>/dev/null | tr ',' '\n' | grep -qx discard; }
deploy_val() { sed -n "s/^$1=//p" /etc/nomade/deploy-info 2>/dev/null; }
# Partition racine jusqu'au bout du disque (moins la partition de données éventuelle, à 2 Mio près)
root_fills_disk() {
  local p="/sys/class/block/${ROOT_PART##*/}" d="/sys/block/$ROOT_DISK" data end total
  data="$(deploy_val DEPLOY_DATA_GIB)"
  end=$(( $(cat "$p/start") + $(cat "$p/size") ))
  total="$(cat "$d/size")"
  (( total - end - ${data:-0} * 2097152 < 4096 + 34 + 2048 ))
}
fs_fills_device() {
  local bs bc dev
  bs="$(dumpe2fs -h "$ROOT_SRC" 2>/dev/null | awk -F: '/^Block size:/ { print $2 + 0 }')"
  bc="$(dumpe2fs -h "$ROOT_SRC" 2>/dev/null | awk -F: '/^Block count:/ { print $2 + 0 }')"
  dev="$(blockdev --getsize64 "$ROOT_SRC")"
  (( bs * bc * 100 >= dev * 99 ))
}
usb_rule_for() { grep -qs "ATTRS{idVendor}==\"${1%:*}\", ATTRS{idProduct}==\"${1#*:}\"" /etc/udev/rules.d/60-nomade-usb.rules; }
# shellcheck disable=SC2053  # $2 est un motif (ex. *[mq-deadline]*)
disk_attr_is() { [[ "$(cat "/sys/block/$ROOT_DISK/queue/$1" 2>/dev/null)" == $2 ]]; }
usb_power_on() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" == "$1" ]] || continue
    [[ "$(cat "$d/power/control" 2>/dev/null)" == on ]] && return 0
  done
  return 1
}
provisioning_unmap() { grep -qx unmap "/sys/block/$ROOT_DISK/device/scsi_disk/"*/provisioning_mode 2>/dev/null; }
no_live_user() { ! getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' | grep -vqx "$TARGET_USER"; }

# --- Démarrage -------------------------------------------------------------------
say "BEGIN noyau=$(uname -r)"
state="$(timeout 600 systemctl is-system-running --wait 2>/dev/null || true)"
say "INFO system-state=$state"
state_ok() { [[ "$state" == running || "$state" == degraded ]]; }
check E-35 "démarrage terminé (running/degraded)" state_ok
systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | while read -r u; do
  [[ -n "$u" ]] && say "INFO unité-en-échec=$u"
done
check E-35 "graphical.target actif" systemctl is-active --quiet graphical.target
check E-35 "gestionnaire de connexion actif" systemctl is-active --quiet display-manager.service

# --- E-02 système installé ----------------------------------------------------------
for p in casper ubiquity subiquity user-setup; do check E-02 "paquet live absent : $p" pkg_absent "$p"; done
check E-02 "aucun paquet ubiquity-*" no_pkg_matching 'ubiquity*'
check E-02 "aucun paquet *-zorin-live" no_pkg_matching '*-zorin-live'

# --- E-04 / E-08 dépôts, manifeste, informations de build ---------------------------
check E-04 "dépôts Zorin conservés" test -s /etc/apt/sources.list.d/zorin.list
check E-04 "manifeste des paquets livré" test -s /etc/nomade/packages.manifest
check E-08 "/etc/nomade/expected.env" test -s /etc/nomade/expected.env
check E-08 "/etc/nomade/build-info" grep -q '^GIT_COMMIT=' /etc/nomade/build-info
check E-02 "aucun utilisateur live" no_live_user
check E-02 "pas de montage casper" bash -c '! grep -qs casper /proc/cmdline'

# --- E-07 fstab / montage --------------------------------------------------------
for o in noatime lazytime commit=60 errors=remount-ro; do check E-07 "racine montée avec $o" root_has_opt "$o"; done
check E-07 "fstab : racine désignée par UUID" grep -Eq '^UUID=[0-9a-f-]+[[:space:]]+/[[:space:]]' /etc/fstab

# --- E-09 / E-10 démarrage UEFI ---------------------------------------------------
check E-09 "chemin amovible EFI/BOOT/BOOTX64.EFI" test -f /boot/efi/EFI/BOOT/BOOTX64.EFI
check E-09 "grubx64.efi à côté du shim" test -f /boot/efi/EFI/BOOT/grubx64.efi
check E-09 "shim-signed installé" pkg_installed shim-signed
check E-09 "grub-efi-amd64-signed installé" pkg_installed grub-efi-amd64-signed
check E-09 "debconf force_efi_extra_removable=true" debconf_is grub-efi-amd64 grub2/force_efi_extra_removable true
check E-09 "debconf update_nvram=false" debconf_is grub-efi-amd64 grub2/update_nvram false
check E-09 "BOOTX64.EFI = shim installé" same_file $ESP/BOOT/BOOTX64.EFI $ESP/ubuntu/shimx64.efi
check E-09 "EFI/BOOT/grubx64.efi = GRUB installé" same_file $ESP/BOOT/grubx64.efi $ESP/ubuntu/grubx64.efi
check E-09 "EFI/BOOT/grubx64.efi = GRUB signé (pas gcdx64)" \
  same_file $ESP/BOOT/grubx64.efi /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed
check E-09 "mmx64.efi dans EFI/BOOT" test -f $ESP/BOOT/mmx64.efi
check E-09 "ni fbx64.efi ni BOOTX64.CSV dans EFI/BOOT" no_fallback
check E-09 "EFI/ubuntu/grub.cfg présent" test -f $ESP/ubuntu/grub.cfg
check E-09 "grub-install dévié vers l'enveloppe --no-nvram (D-033)" grub_install_wrapped
check E-09 "crochet APT de resynchronisation" test -f /etc/apt/apt.conf.d/99-nomade-no-shim-fallback
check E-09 "efibootmgr absent" pkg_absent efibootmgr
sb="$(sb_state)"; say "INFO secureboot=$sb"
expect_sb="$(fwval expect_sb)"
if [[ -n "$expect_sb" ]]; then check E-10 "Secure Boot = $expect_sb" test "$sb" = "$expect_sb"; fi

# --- E-11 / E-12 GRUB et initramfs ---------------------------------------------------
check E-11 "menu GRUB visible" test -f /etc/default/grub.d/60-nomade.cfg
check E-11 "grub.cfg : délai de 3 s" grep -q 'set timeout=3' /boot/grub/grub.cfg
check E-11 "grub.cfg : menu affiché" grep -q 'set timeout_style=menu' /boot/grub/grub.cfg
check E-41 "GRUB_DISABLE_OS_PROBER=true" conf_has /etc/default/grub.d/60-nomade.cfg '^GRUB_DISABLE_OS_PROBER=true$'
check E-41 "aucune entrée os-prober dans grub.cfg" bash -c '! grep -qi osprober /boot/grub/grub.cfg'
check E-12 "pas d'hibernation (aucun resume= au démarrage)" bash -c '! grep -q "resume=" /proc/cmdline'
check E-12 "initramfs : disposition clavier console embarquée (D-034)" \
  initrd_has etc/console-setup/cached_UTF-8_del.kmap.gz
check E-12 "initramfs MODULES=most" conf_has /etc/initramfs-tools/initramfs.conf '^MODULES=most'
check E-12 "initramfs RESUME=none" conf_has '/etc/initramfs-tools/conf.d/*' '^RESUME=none'
for m in uas usb-storage xhci-pci; do check E-12 "module $m disponible au démarrage" early_module "$m"; done

# --- E-13 / E-14 pilotes, firmwares, microcodes -------------------------------------
check E-13 "aucun pilote NVIDIA propriétaire" no_pkg_matching 'nvidia-driver-*'
check E-13 "aucun module nvidia chargé" bash -c '! grep -q "^nvidia " /proc/modules'
check E-14 "linux-firmware installé" pkg_installed linux-firmware
check E-14 "microcode Intel installé" pkg_installed intel-microcode
check E-14 "microcode AMD installé" pkg_installed amd64-microcode

# --- E-15 à E-18 localisation et identité --------------------------------------------
check E-15 "locale $TARGET_LOCALE" conf_has /etc/default/locale "^LANG=\"?$TARGET_LOCALE\"?$"
check E-15 "clavier $TARGET_KEYMAP" conf_has /etc/default/keyboard "^XKBLAYOUT=\"?$TARGET_KEYMAP\"?$"
check E-15 "fuseau $TARGET_TIMEZONE" timedate_is Timezone "$TARGET_TIMEZONE"
check E-15 "locale $TARGET_LOCALE compilée" locale_built
check E-15 "paquets de langue complets (check-language-support)" lang_complete
check E-15 "sources d'entrée GNOME : $TARGET_KEYMAP" gs_is org.gnome.desktop.input-sources sources "[('xkb', '$TARGET_KEYMAP')]"
check E-15 "console : clavier $TARGET_KEYMAP" test -s /etc/console-setup/cached_UTF-8_del.kmap.gz
check E-16 "horloge matérielle en heure locale" timedate_is LocalRTC yes
check E-17 "hostname $TARGET_HOSTNAME" test "$(hostname)" = "$TARGET_HOSTNAME"
check E-17 "utilisateur $TARGET_USER présent" id "$TARGET_USER"
check E-17 "UID 1000 pour $TARGET_USER" test "$(id -u "$TARGET_USER" 2>/dev/null)" = 1000
check E-17 "$TARGET_USER dans le groupe sudo" user_has_group sudo
DEPLOYED="$(fwval deployed)"
if [[ "$DEPLOYED" == 1 ]]; then
  check E-31 "compte $TARGET_USER déverrouillé (mot de passe du déploiement)" user_unlocked
else
  check E-17 "compte $TARGET_USER verrouillé dans l'image" user_locked
fi
check E-18 "pas de serveur SSH" pkg_absent openssh-server
check E-18 "aucun service n'écoute sur le port 22" no_listen_ssh

# --- E-19 à E-26 réactivité et longévité ------------------------------------------
check E-19 "vm.dirty_background_bytes" sysctl_is vm.dirty_background_bytes 268435456
check E-19 "vm.dirty_bytes" sysctl_is vm.dirty_bytes 1073741824
check E-19 "vm.dirty_expire_centisecs" sysctl_is vm.dirty_expire_centisecs 6000
check E-19 "vm.dirty_writeback_centisecs" sysctl_is vm.dirty_writeback_centisecs 1500
check E-19 "vm.swappiness" sysctl_is vm.swappiness 180
check E-19 "vm.page-cluster" sysctl_is vm.page-cluster 0
check E-20 "générateur zram installé" any_pkg_installed systemd-zram-generator zram-tools
check E-20 "échange uniquement sur zram" only_zram_swap
check E-20 "zram : zstd, 50 % de la RAM" zram_ok
check E-20 "zram : priorité 100" zram_prio
check E-20 "aucun fichier d'échange dans fstab" bash -c '! grep -Eq "^[^#].*[[:space:]]swap[[:space:]]" /etc/fstab'
check E-21 "/tmp en tmpfs" fstype_is /tmp tmpfs
check E-22 "journal persistant" test -d "/var/log/journal/$(cat /etc/machine-id)"
check E-22 "journal plafonné à 200 Mo" journald_cap
check E-23 "dpkg force-unsafe-io" test -f /etc/dpkg/dpkg.cfg.d/60-nomade-unsafe-io
check E-24 "fstrim.timer activé" systemctl is-enabled --quiet fstrim.timer
check E-25 "profile-sync-daemon installé" pkg_installed profile-sync-daemon
check E-25 "psd activé pour les sessions" test -e /etc/systemd/user/default.target.wants/psd.service
check E-25 "définition psd pour Brave" conf_has /usr/share/psd/browsers/brave 'BraveSoftware/Brave-Browser'
check E-26 "profil dconf avec system-db:local" conf_has /etc/dconf/profile/user '^system-db:local$'
check E-26 "base dconf local compilée" test -f /etc/dconf/db/local
check E-26 "Tracker : extraction du contenu coupée (max-bytes=0)" gs_is org.freedesktop.Tracker3.Extract max-bytes 0
check E-26 "Tracker : noms de fichiers toujours indexés" \
  gs_not org.freedesktop.Tracker3.Miner.Files index-recursive-directories '@as []'
check E-26 "GNOME Logiciels : pas de téléchargement en arrière-plan" gs_is org.gnome.software download-updates false

# --- E-27 / E-39 / E-40 paquets retirés, services désactivés -----------------------
check E-27 "snapd absent" pkg_absent snapd
check E-27 "gnome-software-plugin-snap absent" pkg_absent gnome-software-plugin-snap
check E-27 "pas de /snap" test ! -e /snap
check E-39 "zorin-os-census absent" pkg_absent zorin-os-census
for u in smartd.service NetworkManager-wait-online.service whoopsie.service whoopsie.path \
         kerneloops.service ModemManager.service; do
  check E-40 "$u désactivé" unit_off "$u"
done
check E-40 "unattended-upgrades conservé (D-022)" pkg_installed unattended-upgrades

# --- E-29 à E-33 clé déployée (scripts/deploy-test.sh) --------------------------------
if [[ "$DEPLOYED" == 1 ]]; then
  say "INFO racine=$ROOT_SRC partition=$ROOT_PART disque=$ROOT_DISK"
  check E-33 "/etc/nomade/deploy-info" test -s /etc/nomade/deploy-info
  check E-29 "partition racine agrandie jusqu'au bout du disque" root_fills_disk
  check E-29 "système de fichiers racine agrandi" fs_fills_device
  if [[ "$(deploy_val DEPLOY_ENCRYPT)" == 1 ]]; then
    check E-30 "racine sur dm-crypt" root_is_crypt
    check E-30 "LUKS2" luks_is_v2
    check E-30 "drapeaux LUKS persistants (allow-discards, no-*-workqueue)" luks_flags
    check E-30 "mappeur actif avec discards et sans files de travail" dm_flags
    check E-30 "crypttab : option discard" crypttab_discard
    check E-30 "/boot en clair" boot_plain
    check E-30 "initramfs : crypttab de la racine" initrd_has cryptroot/crypttab
  fi
  expect_usb="$(fwval expect_usb)"
  if [[ -n "$expect_usb" ]]; then
    check E-32 "règle udev pour le pont $expect_usb" usb_rule_for "$expect_usb"
    check E-32 "règle appliquée : clé non rotative" disk_attr_is rotational 0
    check E-32 "règle appliquée : ordonnanceur mq-deadline" disk_attr_is scheduler '*\[mq-deadline\]*'
    check E-32 "règle appliquée : autosuspend USB désactivé" usb_power_on "$expect_usb"
    if [[ "$(deploy_val DEPLOY_DISCARD)" == 1 ]]; then
      check E-32 "règle appliquée : provisioning_mode=unmap" provisioning_unmap
    fi
  fi
fi

# --- Rapport --------------------------------------------------------------------
journalctl -b -p err --no-pager -o short-monotonic 2>/dev/null | tail -n 40 | while IFS= read -r l; do
  say "LOG $l"
done
if ((FAILS == 0)); then say "RESULT=PASS"; else say "RESULT=FAIL ($FAILS)"; fi

if [[ "$(fwval poweroff)" == 1 ]]; then
  sleep 20      # laisse au harnais le temps de faire une capture d'écran
  systemctl poweroff
fi
