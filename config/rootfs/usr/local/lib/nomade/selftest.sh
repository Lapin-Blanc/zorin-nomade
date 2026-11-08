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
for p in casper ubiquity subiquity; do check E-02 "paquet live absent : $p" pkg_absent "$p"; done
check E-02 "aucun utilisateur live" no_live_user
check E-02 "pas de montage casper" bash -c '! grep -qs casper /proc/cmdline'

# --- E-07 fstab / montage --------------------------------------------------------
for o in noatime lazytime commit=60; do check E-07 "racine montée avec $o" root_has_opt "$o"; done

# --- E-09 / E-10 démarrage UEFI ---------------------------------------------------
check E-09 "chemin amovible EFI/BOOT/BOOTX64.EFI" test -f /boot/efi/EFI/BOOT/BOOTX64.EFI
check E-09 "grubx64.efi à côté du shim" test -f /boot/efi/EFI/BOOT/grubx64.efi
check E-09 "shim-signed installé" pkg_installed shim-signed
check E-09 "grub-efi-amd64-signed installé" pkg_installed grub-efi-amd64-signed
check E-09 "debconf force_efi_extra_removable=true" \
  bash -c "debconf-show grub-efi-amd64 2>/dev/null | grep -Eq 'force_efi_extra_removable: true'"
sb="$(sb_state)"; say "INFO secureboot=$sb"
expect_sb="$(fwval expect_sb)"
if [[ -n "$expect_sb" ]]; then check E-10 "Secure Boot = $expect_sb" test "$sb" = "$expect_sb"; fi

# --- E-11 / E-12 GRUB et initramfs ---------------------------------------------------
check E-11 "menu GRUB visible" test -f /etc/default/grub.d/60-nomade.cfg
check E-12 "initramfs MODULES=most" conf_has /etc/initramfs-tools/initramfs.conf '^MODULES=most'
check E-12 "initramfs RESUME=none" conf_has '/etc/initramfs-tools/conf.d/*' '^RESUME=none'
for m in uas usb-storage xhci-pci; do check E-12 "module $m disponible au démarrage" early_module "$m"; done

# --- E-13 / E-14 pilotes, firmwares, microcodes -------------------------------------
check E-13 "aucun pilote NVIDIA propriétaire" no_pkg_matching 'nvidia-driver-*'
check E-14 "linux-firmware installé" pkg_installed linux-firmware
check E-14 "microcode Intel installé" pkg_installed intel-microcode
check E-14 "microcode AMD installé" pkg_installed amd64-microcode

# --- E-15 à E-18 localisation et identité --------------------------------------------
check E-15 "locale $TARGET_LOCALE" conf_has /etc/default/locale "^LANG=\"?$TARGET_LOCALE\"?$"
check E-15 "clavier $TARGET_KEYMAP" conf_has /etc/default/keyboard "^XKBLAYOUT=\"?$TARGET_KEYMAP\"?$"
check E-15 "fuseau $TARGET_TIMEZONE" timedate_is Timezone "$TARGET_TIMEZONE"
check E-16 "horloge matérielle en heure locale" timedate_is LocalRTC yes
check E-17 "hostname $TARGET_HOSTNAME" test "$(hostname)" = "$TARGET_HOSTNAME"
check E-17 "utilisateur $TARGET_USER présent" id "$TARGET_USER"
check E-17 "compte $TARGET_USER verrouillé dans l'image" user_locked
check E-18 "pas de serveur SSH" pkg_absent openssh-server

# --- E-19 à E-26 réactivité et longévité ------------------------------------------
check E-19 "vm.dirty_background_bytes" sysctl_is vm.dirty_background_bytes 268435456
check E-19 "vm.dirty_bytes" sysctl_is vm.dirty_bytes 1073741824
check E-19 "vm.dirty_expire_centisecs" sysctl_is vm.dirty_expire_centisecs 6000
check E-19 "vm.dirty_writeback_centisecs" sysctl_is vm.dirty_writeback_centisecs 1500
check E-19 "vm.swappiness" sysctl_is vm.swappiness 180
check E-19 "vm.page-cluster" sysctl_is vm.page-cluster 0
check E-20 "générateur zram installé" any_pkg_installed systemd-zram-generator zram-tools
check E-20 "échange uniquement sur zram" only_zram_swap
check E-21 "/tmp en tmpfs" fstype_is /tmp tmpfs
check E-22 "journal persistant" test -d /var/log/journal
check E-23 "dpkg force-unsafe-io" test -f /etc/dpkg/dpkg.cfg.d/60-nomade-unsafe-io
check E-24 "fstrim.timer activé" systemctl is-enabled --quiet fstrim.timer
check E-25 "profile-sync-daemon installé" pkg_installed profile-sync-daemon
check E-25 "psd activé pour les sessions" test -e /etc/systemd/user/default.target.wants/psd.service
check E-26 "profil dconf avec system-db:local" conf_has /etc/dconf/profile/user '^system-db:local$'
check E-26 "base dconf local compilée" test -f /etc/dconf/db/local

# --- Rapport --------------------------------------------------------------------
journalctl -b -p err --no-pager -o short-monotonic 2>/dev/null | tail -n 40 | while IFS= read -r l; do
  say "LOG $l"
done
if ((FAILS == 0)); then say "RESULT=PASS"; else say "RESULT=FAIL ($FAILS)"; fi

if [[ "$(fwval poweroff)" == 1 ]]; then
  sleep 20      # laisse au harnais le temps de faire une capture d'écran
  systemctl poweroff
fi
