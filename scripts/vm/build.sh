#!/usr/bin/env bash
# shellcheck disable=SC2016  # formats dpkg-query ${…} : à ne pas développer
# Construit l'image zorin-nomade (SPEC E-02 à E-12, E-15 à E-17) à partir du squashfs de l'ISO.
# S'exécute en ROOT, dans la VM de build (via scripts/build-image.sh) ou sur un runner CI (D-017).
# Ne touche à aucun disque réel : tout se passe dans un fichier image monté en loop, dans un
# espace de montage privé.
#
#   sudo scripts/vm/build.sh --iso <fichier.iso> --out <dossier> --cache <cache-apt> \
#                            [--stamp AAAAMMJJ-HHMM] [--commit <id>]
#
# Produit dans <dossier> (SPEC E-05) : zorin-nomade-<stamp>.img, .bmap, .manifest, .sha256 et le
# lien latest.img. Idempotent : chaque exécution repart d'un fichier neuf ; seul le cache APT
# (hors image) est réutilisé.
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
load_env

[[ $EUID -eq 0 ]] || die "à lancer en root (sudo), dans la VM de build ou sur un runner CI"
# Espace de montage privé : nos montages ne se propagent pas aux services de la machine de build
# et disparaissent avec le script, même en cas d'arrêt brutal.
if [[ -z "${NOMADE_PRIVATE_NS:-}" ]]; then
  exec env NOMADE_PRIVATE_NS=1 unshare --mount --propagation private "$0" "$@"
fi

ISO="" OUT="" APT_CACHE="" STAMP="$(date +%Y%m%d-%H%M)" COMMIT=inconnu
while (($#)); do
  case "$1" in
    --iso) ISO="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --cache) APT_CACHE="${2:?}"; shift 2 ;;
    --stamp) STAMP="${2:?}"; shift 2 ;;
    --commit) COMMIT="${2:?}"; shift 2 ;;
    *) die "option inconnue : $1" ;;
  esac
done
[[ -f "$ISO" ]] || die "ISO introuvable : ${ISO:-(--iso manquant)}"
[[ -n "$OUT" && -n "$APT_CACHE" ]] || die "--out et --cache sont obligatoires"
[[ "$STAMP" =~ ^[0-9]{8}-[0-9]{4}$ ]] || die "--stamp attend AAAAMMJJ-HHMM (reçu : $STAMP)"
require_cmd unshare unsquashfs sgdisk mkfs.vfat mkfs.ext4 losetup partx blkid e2fsck fstrim \
            bmaptool sha256sum findmnt mountpoint chroot comm
mkdir -p "$OUT" "$APT_CACHE/partial"
OUT="$(realpath "$OUT")" APT_CACHE="$(realpath "$APT_CACHE")"

NAME="$PROJECT_NAME-$STAMP"
IMG="$OUT/$NAME.img"
PART="$OUT/.$NAME.img.part"          # devient $IMG seulement si tout a réussi
PKG="$NOMADE_ROOT/config/packages"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nomade-build.XXXXXX")"
ISO_MNT="$WORK/iso" R="$WORK/root"
mkdir -p "$ISO_MNT" "$R"
LOOP="" P1="" P2="" P3=""
T0=$SECONDS

step() { log "=== $* ($(((SECONDS - T0) / 60)) min)"; }

# in_chroot <commande…> : environnement propre, non interactif, sans dépendre des locales.
in_chroot() {
  chroot "$R" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    "$@"
}
APT=(apt-get -y -q -o Dpkg::Use-Pty=0 -o APT::Sandbox::User=root
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Liste « un paquet par ligne, # commente » → noms triés.
read_list() { sed -e 's/#.*//' "$1" | awk 'NF { print $1 }' | sort -u; }
installed_pkgs() {
  in_chroot dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" { print $2 }' | sort -u
}

# Processus lancés dans le chroot par les scripts des paquets : ils bloqueraient le démontage.
kill_chroot() {
  local p root killed=0
  for p in /proc/[0-9]*; do
    root="$(readlink "$p/root" 2>/dev/null || true)"
    if [[ "$root" == "$R" ]]; then
      warn "processus resté dans le chroot : ${p#/proc/} ($(cat "$p/comm" 2>/dev/null || echo ?))"
      kill -9 "${p#/proc/}" 2>/dev/null || true
      killed=1
    fi
  done
  if ((killed)); then sleep 1; fi
  return 0
}

cleanup() {
  local rc=$?
  set +e
  trap - ERR
  if mountpoint -q "$R"; then kill_chroot; umount -R "$R" || umount -R -l "$R"; fi
  if mountpoint -q "$WORK/boot" 2>/dev/null; then umount "$WORK/boot"; fi
  if mountpoint -q "$ISO_MNT"; then umount "$ISO_MNT"; fi
  if [[ -n "$LOOP" ]]; then losetup -d "$LOOP"; fi
  # Jamais de rm -r ici : $R pourrait encore porter le /dev de la machine de build.
  rm -f "$WORK/manifest-remove" "$WORK/sim.txt" "$WORK/hosts" "$WORK/default-grub" "$WORK/reinstall.txt"
  rmdir "$R" "$ISO_MNT" "$WORK/boot" "$WORK" 2>/dev/null
  if ((rc != 0)); then
    rm -f "$PART"
    printf 'ERREUR construction interrompue (code %s) : image partielle supprimée\n' "$rc" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

# --------------------------------------------------------------------------------------------
step "Vérification de l'ISO $(basename "$ISO")"
echo "${ISO_SHA256,,}  $ISO" | sha256sum -c --quiet - || die "SHA-256 de l'ISO incorrect"
mount -o loop,ro "$ISO" "$ISO_MNT"
for f in casper/filesystem.squashfs casper/filesystem.manifest-remove; do
  [[ -f "$ISO_MNT/$f" ]] || die "$f absent de l'ISO (schéma Ubiquity attendu, docs/iso-notes.md § 2)"
done
cp "$ISO_MNT/casper/filesystem.manifest-remove" "$WORK/manifest-remove"

# --------------------------------------------------------------------------------------------
step "Image creuse et table GPT (E-06)"
size_mib=$((1 + IMAGE_ESP_MIB + IMAGE_BOOT_MIB + IMAGE_ROOT_GIB * 1024 + 1))
rm -f "$PART"
truncate -s "${size_mib}M" "$PART"
sgdisk -n "1:1MiB:+${IMAGE_ESP_MIB}MiB" -t 1:EF00 -c 1:NOMADE-ESP \
       -n "2:0:+${IMAGE_BOOT_MIB}MiB"   -t 2:8300 -c 2:nomade-boot \
       -n 3:0:0                         -t 3:8300 -c 3:nomade-root "$PART" >/dev/null
LOOP="$(losetup --show -f -P "$PART")"
udevadm settle 2>/dev/null || true
for i in 1 2 3; do [[ -b "${LOOP}p$i" ]] || partx -a "$LOOP" 2>/dev/null || true; done
P1="${LOOP}p1" P2="${LOOP}p2" P3="${LOOP}p3"
for p in "$P1" "$P2" "$P3"; do [[ -b "$p" ]] || die "partition $p absente"; done
mkfs.vfat -F 32 -n NOMADE-ESP "$P1" >/dev/null
mkfs.ext4 -q -F -L nomade-boot "$P2"
mkfs.ext4 -q -F -L nomade-root "$P3"
U1="$(blkid -s UUID -o value "$P1")"
U2="$(blkid -s UUID -o value "$P2")"
U3="$(blkid -s UUID -o value "$P3")"
log "ESP $U1 · /boot $U2 · racine $U3 · ${size_mib} Mio"

# --------------------------------------------------------------------------------------------
step "Décompression du squashfs dans la racine (E-03)"
mount "$P3" "$R"
unsquashfs -f -no-progress -d "$R" "$ISO_MNT/casper/filesystem.squashfs" | tail -n 2
umount "$ISO_MNT"
[[ -x "$R/usr/bin/apt-get" && -f "$R/etc/os-release" ]] || die "racine incomplète après unsquashfs"
grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' "$R/etc/os-release"

# /boot sur p2, ESP sur /boot/efi
mkdir -p "$WORK/boot"
mount "$P2" "$WORK/boot"
cp -a "$R/boot/." "$WORK/boot/"
umount "$WORK/boot"
find "$R/boot" -mindepth 1 -delete
mount "$P2" "$R/boot"
mkdir -p "$R/boot/efi"
mount "$P1" "$R/boot/efi"

# --------------------------------------------------------------------------------------------
step "Préparation du chroot"
mount --rbind /dev "$R/dev"
mount --make-rslave "$R/dev"
mount -t proc proc "$R/proc"
mount -t sysfs sysfs "$R/sys"          # sans efivarfs : aucune écriture NVRAM possible
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$R/run"
mkdir -p "$R/run/systemd/resolve" "$R/run/lock"
# /etc/resolv.conf est un lien vers ../run/systemd/resolve/stub-resolv.conf (iso-notes § 8) :
# on remplit la cible du lien, sans toucher au lien.
resolv=/run/systemd/resolve/resolv.conf
[[ -s "$resolv" ]] || resolv=/etc/resolv.conf
cp -L "$resolv" "$R/run/systemd/resolve/stub-resolv.conf"

# Aucun service ne démarre pendant la construction
[[ ! -e "$R/usr/sbin/policy-rc.d" ]] || die "policy-rc.d déjà présent dans le squashfs (inattendu)"
printf '#!/bin/sh\nexit 101\n' >"$R/usr/sbin/policy-rc.d"
chmod 755 "$R/usr/sbin/policy-rc.d"

# Cache APT hors de l'image (leçon Debian, iso-notes § 7)
mount --bind "$APT_CACHE" "$R/var/cache/apt/archives"

# Overlay config/rootfs AVANT les paquets : grub.d (os-prober coupé pendant update-grub),
# crochet anti-fbx64, dpkg unsafe-io, RESUME=none… sont pris en compte dès la transaction APT.
# Jamais d'écrasement à l'aveugle d'un fichier du squashfs (CLAUDE.md).
overlay_copy() {
  local src="$NOMADE_ROOT/config/rootfs" f rel n=0
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    if [[ -e "$R/$rel" || -L "$R/$rel" ]] && ! cmp -s "$f" "$R/$rel"; then
      die "l'overlay écraserait /$rel du squashfs : fusion à prévoir et à consigner (docs/iso-notes.md)"
    fi
    install -D -o root -g root -m "$(stat -c %a "$f")" "$f" "$R/$rel"
    n=$((n + 1))
  done < <(find "$src" -type f -print0)
  log "overlay : $n fichiers copiés"
}
overlay_copy

# GRUB : chemin amovible maintenu, jamais de NVRAM (E-09) — avant l'installation de GRUB.
# Clavier : réponses cohérentes avec /etc/default/keyboard écrit plus bas (E-15).
in_chroot debconf-set-selections <<EOF
grub-efi-amd64 grub2/force_efi_extra_removable boolean true
grub-efi-amd64 grub2/update_nvram boolean false
keyboard-configuration keyboard-configuration/layoutcode string $TARGET_KEYMAP
keyboard-configuration keyboard-configuration/xkb-keymap select $TARGET_KEYMAP
EOF
# D-033 : grub-install dévié vers une enveloppe qui impose --no-nvram, y compris lors des mises à
# jour de GRUB et de shim sur la clé (grub-multi-install ignore grub2/update_nvram).
in_chroot dpkg-divert --local --rename --divert /usr/sbin/grub-install.real --add /usr/sbin/grub-install
ln -sfn /usr/local/lib/nomade/grub-install-no-nvram "$R/usr/sbin/grub-install"
[[ -x "$R/usr/sbin/grub-install.real" ]] || die "dpkg-divert de grub-install inopérant"

# --------------------------------------------------------------------------------------------
step "APT : transaction unique à la manière d'Ubiquity (D-014)"
in_chroot "${APT[@]}" update
mapfile -t ADD < <(read_list "$PKG/add.list")
# à retirer = (manifest-remove − à garder) + retraits supplémentaires, limité à l'installé
mapfile -t REMOVE < <(
  { comm -23 <(read_list "$WORK/manifest-remove") <(read_list "$PKG/keep.list")
    read_list "$PKG/remove.list"; } | sort -u | comm -12 - <(installed_pkgs)
)
log "${#ADD[@]} paquets à installer, ${#REMOVE[@]} à purger (manifeste $(read_list "$WORK/manifest-remove" | wc -l), gardés $(read_list "$PKG/keep.list" | wc -l))"
TRANS=("${ADD[@]}" "${REMOVE[@]/%/-}")
in_chroot apt-get -s -o Dpkg::Use-Pty=0 --purge --auto-remove install "${TRANS[@]}" >"$WORK/sim.txt"
log "simulation : $(grep -c '^Inst ' "$WORK/sim.txt" || true) installations, $(grep -c '^Purg ' "$WORK/sim.txt" || true) purges"
extra="$(comm -13 <(printf '%s\n' "${REMOVE[@]}" | sort -u) \
                  <(awk '/^Purg /{ print $2 }' "$WORK/sim.txt" | sed 's/:.*//' | sort -u) | tr '\n' ' ')"
log "purgés en plus de la liste (dépendances devenues inutiles) : ${extra:-aucun}"
log "purgés : $(printf '%s ' "${REMOVE[@]}")"
# /etc/default/grub (réglages Zorin : quiet splash, thème, GRUB_DISTRIBUTOR) est géré par ucf pour
# grub-pc : la purge de grub-pc le supprime alors que grub-efi-amd64 vient de le reprendre (D-032).
[[ -f "$R/etc/default/grub" ]] || die "/etc/default/grub absent du squashfs (inattendu)"
cp -a "$R/etc/default/grub" "$WORK/default-grub"
in_chroot "${APT[@]}" --purge --auto-remove install "${TRANS[@]}"
if [[ -f "$R/etc/default/grub" ]]; then
  cmp -s "$WORK/default-grub" "$R/etc/default/grub" \
    || warn "/etc/default/grub modifié par la transaction APT (gardé tel quel)"
else
  install -m 644 "$WORK/default-grub" "$R/etc/default/grub"
  log "/etc/default/grub de Zorin restauré (supprimé par la purge de grub-pc)"
fi

step "APT : full-upgrade et purge des anciens noyaux (E-04)"
in_chroot "${APT[@]}" full-upgrade
in_chroot "${APT[@]}" --purge autoremove

# Ubuntu garde le noyau précédent comme secours (apt-auto-removal) : on ne garde que le plus
# récent, comme une installation neuve (place sur la clé, initramfs régénérés une seule fois).
mapfile -t KERNELS < <(find "$R/boot" -maxdepth 1 -name 'vmlinuz-*-generic' -printf '%f\n' \
                       | sed 's/^vmlinuz-//; s/-generic$//' | sort -V)
if ((${#KERNELS[@]} > 1)); then
  INSTALLED="$(installed_pkgs)"
  old_pkgs=()
  for v in "${KERNELS[@]:0:${#KERNELS[@]}-1}"; do
    mapfile -t -O "${#old_pkgs[@]}" old_pkgs < <(grep -E "^linux-.*-${v//./\\.}(-generic)?$" <<<"$INSTALLED" || true)
  done
  log "purge des anciens noyaux : ${old_pkgs[*]}"
  in_chroot "${APT[@]}" --purge remove "${old_pkgs[@]}"
  in_chroot "${APT[@]}" --purge autoremove
fi

# Contrôle E-02 / E-27 / E-39 : aucun paquet live, ni snapd, ni census
INSTALLED="$(installed_pkgs)"
live="$(grep -E '^(casper|ubiquity.*|user-setup|.*-zorin-live|snapd|zorin-os-census.*)$' <<<"$INSTALLED" \
        | tr '\n' ' ' || true)"
[[ -z "$live" ]] || die "paquets live ou retirés encore présents : $live"
for p in "${ADD[@]}"; do grep -qx "$p" <<<"$INSTALLED" || die "paquet attendu absent : $p"; done
mapfile -t KERNELS < <(find "$R/boot" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sort -V)
log "noyau(x) : ${KERNELS[*]#vmlinuz-}"
((${#KERNELS[@]} == 1)) || warn "plusieurs noyaux dans /boot"

# --------------------------------------------------------------------------------------------
step "Configuration du système (E-07, E-08, E-15 à E-17)"
cat >"$R/etc/fstab" <<EOF
# zorin-nomade (SPEC E-07) — systèmes de fichiers désignés par UUID
# <système de fichiers>                      <montage>  <type> <options>                                    <dump> <pass>
UUID=$U3  /          ext4   noatime,lazytime,commit=60,errors=remount-ro  0      1
UUID=$U2  /boot      ext4   noatime,lazytime                              0      2
UUID=$U1                             /boot/efi  vfat   umask=0077                                    0      1
EOF

echo "$TARGET_HOSTNAME" >"$R/etc/hostname"
{
  printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$TARGET_HOSTNAME"
  grep -vE '^127\.0\.[01]\.1[[:space:]]' "$R/etc/hosts" || true
} >"$WORK/hosts"
install -m 644 "$WORK/hosts" "$R/etc/hosts"

# E-16 : horloge matérielle en heure locale (PC Windows)
printf '0.0 0 0.0\n0\nLOCAL\n' >"$R/etc/adjtime"

# E-15 : locale, clavier, fuseau
in_chroot locale-gen "$TARGET_LOCALE" en_US.UTF-8
in_chroot update-locale "LANG=$TARGET_LOCALE" "LANGUAGE=$TARGET_LANGUAGE"
cat >"$R/etc/default/keyboard" <<EOF
# zorin-nomade (SPEC E-15)
XKBMODEL="pc105"
XKBLAYOUT="$TARGET_KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
if [[ -x "$R/usr/bin/setupcon" ]]; then in_chroot setupcon --save-only
else warn "setupcon absent : clavier console non préparé"; fi
ln -sfn "/usr/share/zoneinfo/$TARGET_TIMEZONE" "$R/etc/localtime"
echo "$TARGET_TIMEZONE" >"$R/etc/timezone"
in_chroot dpkg-reconfigure -f noninteractive tzdata 2>&1 | tail -n 2

# E-17 : utilisateur UID 1000, groupes du premier utilisateur Ubuntu, compte verrouillé
groups=()
for g in adm cdrom dip lpadmin plugdev sambashare users sudo; do
  if in_chroot getent group "$g" >/dev/null; then groups+=("$g"); else warn "groupe absent : $g"; fi
done
in_chroot useradd -m -u 1000 -U -s /bin/bash -c "$TARGET_USER_FULLNAME" \
  -G "$(IFS=,; echo "${groups[*]}")" "$TARGET_USER"
in_chroot passwd -l "$TARGET_USER" >/dev/null
log "utilisateur : $(in_chroot id "$TARGET_USER")"

# machine-id vide : régénéré au premier démarrage, propre à chaque clé
: >"$R/etc/machine-id"
if [[ -f "$R/var/lib/dbus/machine-id" && ! -L "$R/var/lib/dbus/machine-id" ]]; then
  rm -f "$R/var/lib/dbus/machine-id"
fi

# E-08 : valeurs attendues par l'autotest, informations de build
install -d -m 755 "$R/etc/nomade"
cat >"$R/etc/nomade/expected.env" <<EOF
# zorin-nomade (SPEC E-08) — valeurs attendues par l'autotest, écrites au build
TARGET_HOSTNAME=$TARGET_HOSTNAME
TARGET_USER=$TARGET_USER
TARGET_LOCALE=$TARGET_LOCALE
TARGET_KEYMAP=$TARGET_KEYMAP
TARGET_TIMEZONE=$TARGET_TIMEZONE
EOF
cat >"$R/etc/nomade/build-info" <<EOF
# zorin-nomade (SPEC E-08)
BUILD_NAME=$NAME
BUILD_DATE=$(date -Iseconds)
GIT_COMMIT=$COMMIT
ISO_EDITION=$ISO_EDITION
ISO_VERSION=$ISO_VERSION
ISO_SHA256=$ISO_SHA256
KERNEL=${KERNELS[-1]#vmlinuz-}
EOF

in_chroot systemctl enable nomade-selftest.service
default_target="$(in_chroot systemctl get-default)"
if [[ "$default_target" != graphical.target ]]; then
  in_chroot systemctl set-default graphical.target
fi
log "cible par défaut : $(in_chroot systemctl get-default)"

# L'overlay doit être intact après la transaction APT
while IFS= read -r -d '' f; do
  cmp -s "$f" "$R/${f#"$NOMADE_ROOT/config/rootfs/"}" \
    || die "un paquet a modifié /${f#"$NOMADE_ROOT/config/rootfs/"} de l'overlay"
done < <(find "$NOMADE_ROOT/config/rootfs" -type f -print0)

# --------------------------------------------------------------------------------------------
step "initramfs (E-12)"
in_chroot update-initramfs -u -k all

# --------------------------------------------------------------------------------------------
step "GRUB et chemin amovible (E-09, E-11, E-41, D-029)"
in_chroot grub-install --target=x86_64-efi --efi-directory=/boot/efi --uefi-secure-boot --no-nvram
in_chroot /usr/local/lib/nomade/efi-removable-sync.sh
in_chroot update-grub

# Mise à jour simulée de shim et GRUB, par APT comme sur la clé : le chemin amovible doit rester
# cohérent (crochet APT) et aucune écriture NVRAM ne doit être tentée. La machine de build n'expose
# pas de variables EFI au chroot : toute tentative se voit dans la sortie de grub-install.
log "mise à jour simulée de shim-signed et grub-efi-amd64-signed"
in_chroot "${APT[@]}" install --reinstall shim-signed grub-efi-amd64-signed >"$WORK/reinstall.txt" 2>&1 \
  || { cat "$WORK/reinstall.txt" >&2; die "réinstallation de shim/GRUB en échec"; }
grep -E 'Installing for|Installation finished' "$WORK/reinstall.txt" | sort | uniq -c || true
if grep -qiE 'EFI variables|efibootmgr|nvram' "$WORK/reinstall.txt"; then
  grep -iE 'EFI variables|efibootmgr|nvram' "$WORK/reinstall.txt" >&2
  die "une mise à jour de GRUB/shim tente d'écrire en NVRAM (E-09, D-033)"
fi
[[ "$(readlink "$R/usr/sbin/grub-install")" == /usr/local/lib/nomade/grub-install-no-nvram ]] \
  || die "l'enveloppe grub-install a été remplacée par une mise à jour"

E="$R/boot/efi/EFI"
SIGNED="$R/usr/lib/grub/x86_64-efi-signed"
log "contenu de l'ESP :"
(cd "$R/boot/efi" && find . -type f -printf '  %p %s\n' | sort) >&2
# Dossier fournisseur produit par grub-install (« Zorin OS » sur une installation Zorin réelle)
VENDOR=""
for d in "$E"/*/; do
  d="${d%/}"
  if [[ "$d" != "$E/BOOT" && -f "$d/shimx64.efi" && -f "$d/grubx64.efi" ]]; then
    [[ -z "$VENDOR" ]] || die "plusieurs dossiers fournisseurs dans l'ESP : ${VENDOR#"$E"/}, ${d#"$E"/}"
    VENDOR="$d"
  fi
done
[[ -n "$VENDOR" ]] || die "aucun dossier EFI/<fournisseur> avec shim et GRUB après grub-install"
log "dossier fournisseur : EFI/${VENDOR#"$E"/}"
cmp -s "$VENDOR/grubx64.efi" "$SIGNED/grubx64.efi.signed" || die "grubx64.efi installé n'est pas le GRUB signé"
cmp -s "$E/BOOT/BOOTX64.EFI" "$VENDOR/shimx64.efi" || die "EFI/BOOT/BOOTX64.EFI n'est pas le shim installé"
cmp -s "$E/BOOT/grubx64.efi" "$VENDOR/grubx64.efi" || die "EFI/BOOT/grubx64.efi différent du GRUB installé"
if cmp -s "$E/BOOT/grubx64.efi" "$SIGNED/gcdx64.efi.signed"; then die "variante CD (gcdx64) dans EFI/BOOT"; fi
[[ -f "$E/BOOT/mmx64.efi" ]] || die "EFI/BOOT/mmx64.efi absent"
[[ ! -e "$E/BOOT/fbx64.efi" && ! -e "$E/BOOT/BOOTX64.CSV" ]] || die "fbx64.efi ou BOOTX64.CSV dans EFI/BOOT"
for c in "$VENDOR/grub.cfg" "$E/BOOT/grub.cfg" "$E/ubuntu/grub.cfg"; do
  grep -q "search.fs_uuid $U2 " "$c" || die "${c#"$R"} ne renvoie pas vers /boot ($U2)"
done
[[ -f "$R/boot/grub/grub.cfg" ]] || die "/boot/grub/grub.cfg absent"
if grep -qi osprober "$R/boot/grub/grub.cfg"; then die "entrée os-prober dans grub.cfg (E-41)"; fi
grep -q "root=UUID=$U3" "$R/boot/grub/grub.cfg" || die "grub.cfg ne désigne pas la racine par UUID"
grep -qE "^menuentry '[^']*Zorin" "$R/boot/grub/grub.cfg" \
  || die "première entrée du menu sans « Zorin » : /etc/default/grub de Zorin non pris en compte"
log "menu : $(grep -cE "^\s*menuentry " "$R/boot/grub/grub.cfg") entrées, timeout $(grep -m1 -oE 'set timeout=[0-9]+' "$R/boot/grub/grub.cfg" || echo '?')"

# --------------------------------------------------------------------------------------------
step "Manifeste et nettoyage"
in_chroot dpkg-query -W -f='${Package}\t${Version}\n' >"$OUT/$NAME.manifest"
log "manifeste : $(wc -l <"$OUT/$NAME.manifest") paquets"
# Démonter le cache AVANT apt-get clean : il est partagé entre les builds (hors image).
umount "$R/var/cache/apt/archives"
in_chroot apt-get clean
rm -f "$R/usr/sbin/policy-rc.d" "$R/var/cache/apt/"*.bin "$R/var/cache/debconf/"*-old \
      "$R/var/lib/systemd/random-seed" "$R/root/.bash_history"
find "$R/tmp" "$R/var/tmp" -mindepth 1 -delete
find "$R/var/log" -type f \( -name '*.log' -o -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' \
     -o -name '*.old' \) -delete
for f in wtmp btmp lastlog; do if [[ -f "$R/var/log/$f" ]]; then : >"$R/var/log/$f"; fi; done
df -h "$R" "$R/boot" "$R/boot/efi" | sed 's/^/  /'
fstrim -v "$R/boot/efi" || true
sync

step "Démontage et blocs libres rendus au fichier"
kill_chroot
umount -R "$R"
for d in "$P2" "$P3"; do
  rc=0; e2fsck -f -p -E discard "$d" || rc=$?
  ((rc <= 1)) || die "e2fsck $d : code $rc"
done
losetup -d "$LOOP"
LOOP=""
log "blocs alloués dans l'image : $(du -m "$PART" | cut -f1) Mio (taille apparente ${size_mib} Mio)"

# --------------------------------------------------------------------------------------------
step "Artefacts (E-05)"
mv -f "$PART" "$IMG"
bmaptool create -o "$OUT/$NAME.bmap" "$IMG"
(cd "$OUT" && sha256sum "$NAME.img" >"$NAME.sha256")
ln -sfn "$NAME.img" "$OUT/latest.img"
if [[ -n "${SUDO_UID:-}" ]]; then
  chown -h "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT/$NAME".{img,bmap,manifest,sha256} "$OUT/latest.img"
fi
ls -ls "$OUT"
step "Image prête : $IMG"
