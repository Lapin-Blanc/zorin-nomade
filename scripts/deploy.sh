#!/usr/bin/env bash
# Déploie l'image zorin-nomade sur la clé USB (SPEC E-28 à E-34). S'exécute en ROOT.
#
#   Réel (Fabien) : sudo make deploy KEY=/dev/disk/by-id/usb-…
#                   = sudo scripts/deploy.sh --target /dev/disk/by-id/usb-… [--image out/latest.img]
#   Test (Claude) : DEPLOY_TEST=1 scripts/deploy.sh --target <fichier|/dev/loopN> --image <img>
#                   --usb-id 46f4:0001 --secrets-stdin      (dans la VM de build uniquement)
#
# Étapes : garde-fous (lib.sh) → secrets saisis → pont USB et essai de TRIM → effacement →
# bmaptool → table GPT agrandie (+ partition exFAT NOMADE-DATA si DEPLOY_DATA_GIB > 0) →
# racine : LUKS2 recréé (D-035) ou agrandie en clair → chroot : crypttab, mot de passe, règle udev,
# initramfs, GRUB → contrôles finaux → checklist du premier démarrage.
#
# Secrets : la clé de volume LUKS est générée ici, sur la cible, par cryptsetup ; la phrase de passe
# et le mot de passe ne passent que par des tubes (jamais en argument, jamais dans un fichier ni un
# journal). En test, ils arrivent sur l'entrée standard (deux lignes) et ne servent qu'à ce test.
# Rejouable (E-34) : chaque exécution efface la cible et repart de zéro.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

[[ $EUID -eq 0 ]] || die "à lancer en root : sudo make deploy KEY=/dev/disk/by-id/usb-…"
# Espace de montage privé : les montages du déploiement restent invisibles du bureau (udisks,
# GNOME Fichiers) et disparaissent avec le script, même en cas d'arrêt brutal.
if [[ -z "${NOMADE_PRIVATE_NS:-}" ]]; then
  exec env NOMADE_PRIVATE_NS=1 unshare --mount --propagation private "$0" "$@"
fi

TARGET="" IMAGE="$OUT_DIR/latest.img" USB_ID="" SECRETS_STDIN=0
while (($#)); do
  case "$1" in
    --target) TARGET="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    --usb-id) USB_ID="${2:?}"; shift 2 ;;
    --secrets-stdin) SECRETS_STDIN=1; shift ;;
    *) die "option inconnue : $1" ;;
  esac
done
TEST="${DEPLOY_TEST:-0}"
if [[ "$TEST" != 1 ]] && [[ -n "$USB_ID" || "$SECRETS_STDIN" == 1 ]]; then
  die "--usb-id et --secrets-stdin sont réservés au mode test (DEPLOY_TEST=1)"
fi
require_cmd bmaptool sgdisk partx losetup blkid blockdev wipefs blkdiscard cryptsetup \
            mkfs.ext4 e2fsck resize2fs rsync fsck.vfat chroot findmnt udevadm sha256sum
if ((DEPLOY_DATA_GIB > 0)); then require_cmd mkfs.exfat; fi
if [[ ! "$DEPLOY_INODE_RATIO" =~ ^[0-9]+$ ]] || ((DEPLOY_INODE_RATIO < 4096)); then
  die "DEPLOY_INODE_RATIO invalide : $DEPLOY_INODE_RATIO (octets par inode, ≥ 4096)"
fi

IMAGE="$(readlink -f "$IMAGE")"
BMAP="${IMAGE%.img}.bmap"
[[ -f "$IMAGE" && -f "$BMAP" ]] || die "image ou bmap introuvable : $IMAGE (make image)"
MAPPER=nomade-root                     # nom dans crypttab (et pendant le déploiement si libre)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nomade-deploy.XXXXXX")"
MNT="$WORK/root" SRC="$WORK/src"
mkdir -p "$MNT" "$SRC"
TLOOP="" ILOOP="" OPENED="" UDEV_RULE=""
T0=$SECONDS
step() { log "=== $* ($(((SECONDS - T0) / 60)) min)"; }
part() { if [[ "$1" =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "$1$2"; fi; }

cleanup() {
  local rc=$?
  set +e
  trap - ERR
  if mountpoint -q "$MNT"; then umount -R "$MNT" || umount -R -l "$MNT"; fi
  if mountpoint -q "$SRC"; then umount "$SRC"; fi
  if [[ -n "$OPENED" ]]; then cryptsetup close "$OPENED"; fi
  if [[ -n "$ILOOP" ]]; then losetup -d "$ILOOP"; fi
  if [[ -n "$TLOOP" ]]; then losetup -d "$TLOOP"; fi
  if [[ -n "$UDEV_RULE" ]]; then rm -f "$UDEV_RULE"; udevadm control --reload 2>/dev/null; fi
  unset PASSPHRASE PASSWORD
  rmdir "$MNT" "$SRC" "$WORK" 2>/dev/null
  if ((rc != 0)); then
    printf "ERREUR déploiement interrompu (code %s) : la clé est inutilisable en l'état, relance le déploiement.\n" "$rc" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

# --------------------------------------------------------------------------------------------
step "Garde-fous (E-28)"
if [[ "$TEST" == 1 ]]; then
  assert_test_target "$TARGET"
  if [[ -f "$TARGET" ]]; then
    TLOOP="$(losetup --show -f -P "$TARGET")"
    DEV="$TLOOP"
  else
    DEV="$TARGET"
  fi
else
  assert_real_usb_target "$TARGET"
  DEV="$(readlink -f "$TARGET")"
fi
[[ ! -e "/dev/mapper/$MAPPER" ]] || MAPPER=nomade-root-deploy  # déploiement depuis une clé nomade
[[ ! -e "/dev/mapper/$MAPPER" ]] || die "/dev/mapper/$MAPPER existe déjà : ferme-le d'abord"
DISK_BYTES="$(blockdev --getsize64 "$DEV")"
IMG_BYTES="$(stat -c %s "$IMAGE")"
log "cible $DEV : $((DISK_BYTES / 1024 ** 3)) Gio ; image $(basename "$IMAGE") : $((IMG_BYTES / 1024 ** 3)) Gio"
((DISK_BYTES >= IMG_BYTES + DEPLOY_DATA_GIB * 1024 ** 3 + 4 * 1024 ** 3)) \
  || die "cible trop petite pour l'image (+ ${DEPLOY_DATA_GIB} Gio de données + 4 Gio de marge)"

# Sur la vraie machine, GNOME monterait les partitions dès leur apparition : udisks les ignore
# pendant le déploiement (règle temporaire dans /run, retirée à la fin).
if [[ "$TEST" != 1 ]]; then
  UDEV_RULE=/run/udev/rules.d/99-nomade-deploy-noauto.rules
  mkdir -p /run/udev/rules.d
  printf 'SUBSYSTEM=="block", KERNEL=="%s*", ENV{UDISKS_IGNORE}="1"\n' "$(basename "$DEV")" >"$UDEV_RULE"
  udevadm control --reload
fi
# Démonte ce qu'un automontage aurait pu monter malgré tout (jamais autre chose que la cible).
unmount_target() {
  local p
  while read -r p; do
    [[ -n "$p" ]] || continue
    warn "partition de la cible montée ($p) : démontage"
    umount "$p"
  done < <(lsblk -nrpo MOUNTPOINT "$DEV" | awk NF)
}

# --------------------------------------------------------------------------------------------
step "Secrets (E-30, E-31)"
read_secret() {   # read_secret <libellé> <variable> : saisie double, sans écho
  local a b
  while :; do
    read -r -s -p "$1 : " a </dev/tty; echo >&2
    read -r -s -p "$1 (confirmation) : " b </dev/tty; echo >&2
    if [[ -z "$a" ]]; then warn "vide : recommence"; continue; fi
    if [[ "$a" != "$b" ]]; then warn "différents : recommence"; continue; fi
    if [[ "$a" == *[![:ascii:]]* ]]; then
      warn "caractères non ASCII : la console de l'initramfs risque de ne pas les reproduire ; recommence"
      continue
    fi
    printf -v "$2" '%s' "$a"
    return 0
  done
}
PASSPHRASE="" PASSWORD=""
if ((SECRETS_STDIN)); then
  IFS= read -r PASSPHRASE || true
  IFS= read -r PASSWORD || true
  [[ -n "$PASSPHRASE" && -n "$PASSWORD" ]] || die "--secrets-stdin : deux lignes attendues"
else
  [[ -t 0 || -r /dev/tty ]] || die "saisie interactive requise (terminal)"
  if [[ "$DEPLOY_ENCRYPT" == 1 ]]; then
    log "Phrase de passe LUKS : elle se tapera en clavier BELGE au démarrage (ASCII uniquement)."
    read_secret "Phrase de passe du chiffrement" PASSPHRASE
  fi
  read_secret "Mot de passe de $TARGET_USER" PASSWORD
fi

# --------------------------------------------------------------------------------------------
step "Pont USB et essai de TRIM (E-32)"
if [[ -n "$USB_ID" ]]; then
  VIDPID="$USB_ID"
else
  # Remonte sysfs depuis le disque jusqu'au périphérique USB (idVendor/idProduct)
  d="$(readlink -f "/sys/block/$(basename "$DEV")/device")"
  while [[ "$d" != / && ! -f "$d/idVendor" ]]; do d="$(dirname "$d")"; done
  [[ -f "$d/idVendor" ]] || die "pont USB introuvable dans sysfs pour $DEV"
  VIDPID="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
fi
[[ "$VIDPID" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || die "VID:PID invalide : $VIDPID"
log "pont USB : $VIDPID"

# Le pont annonce-t-il le TRIM ? Sinon, on tente provisioning_mode=unmap le temps d'un essai.
# L'essai porte sur le premier Mio du disque, effacé de toute façon juste après.
# -f et </dev/null : sans -f, blkdiscard (util-linux ≥ 2.36) refuse quand stdin est un terminal
# et que le disque porte déjà une signature (table de partitions) ; l'essai échouait donc sur
# toute clé réelle déjà utilisée, mais pas en test (stdin = tube). Constaté le 2026-11-08.
DISCARD_OK=0 DISCARD_ERR=""
pm_files=()
if [[ "$TEST" != 1 ]]; then
  mapfile -t pm_files < <(find "/sys/block/$(basename "$DEV")/device/scsi_disk/" -name provisioning_mode 2>/dev/null)
fi
pm_old=""
if ((${#pm_files[@]})); then pm_old="$(cat "${pm_files[0]}")"; log "provisioning_mode actuel : $pm_old"; fi
if (($(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes") == 0)) && ((${#pm_files[@]})); then
  echo unmap >"${pm_files[0]}" 2>/dev/null || true
fi
if (($(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes") == 0)); then
  DISCARD_ERR="discard_max_bytes=0 (le pont n'annonce pas le TRIM)"
elif DISCARD_ERR="$(timeout 60 blkdiscard -f -o 0 -l 1048576 "$DEV" </dev/null 2>&1)"; then
  DISCARD_OK=1
else
  DISCARD_ERR="blkdiscard, code $? : ${DISCARD_ERR:-aucun message}"
fi
if ((DISCARD_OK)); then
  log "TRIM : essai réussi → provisioning_mode=unmap dans la règle udev"
else
  log "TRIM : non disponible à travers ce pont → règle udev sans provisioning_mode"
  log "TRIM : cause : ${DISCARD_ERR:-inconnue}"
  if [[ -n "$pm_old" ]]; then echo "$pm_old" >"${pm_files[0]}" 2>/dev/null || true; fi
fi

# --------------------------------------------------------------------------------------------
step "Effacement de la cible et écriture de l'image (E-29, E-34)"
unmount_target
if ((DISCARD_OK)); then blkdiscard -f "$DEV"; else wipefs -a -q "$DEV" 2>/dev/null || true; fi
bmaptool copy --bmap "$BMAP" "$IMAGE" "$DEV" 2>&1 | grep -vE '^\s*$' | tail -n 3 >&2
sync

# --------------------------------------------------------------------------------------------
step "Table GPT : racine agrandie (E-29)"
sgdisk -e "$DEV" >/dev/null                     # en-tête GPT de secours en fin de disque
p3_start="$(sgdisk -i 3 "$DEV" | awk '/^First sector:/ { print $3 }')"
p3_guid="$(sgdisk -i 3 "$DEV" | awk '/^Partition unique GUID:/ { print $4 }')"
last="$(sgdisk -E "$DEV" 2>/dev/null | tail -n 1)"
[[ "$p3_start" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || die "lecture de la table GPT impossible"
if ((DEPLOY_DATA_GIB > 0)); then
  p3_end=$(( ((last + 1 - DEPLOY_DATA_GIB * 2097152) / 2048) * 2048 - 1 ))
else
  p3_end=$(( ((last + 1) / 2048) * 2048 - 1 ))   # multiple de 1 Mio (secteurs LUKS de 4 Kio)
fi
sgdisk -d 3 -n "3:$p3_start:$p3_end" -t 3:8300 -c 3:nomade-root -u "3:$p3_guid" "$DEV" >/dev/null
if ((DEPLOY_DATA_GIB > 0)); then
  sgdisk -n "4:$((p3_end + 1)):$last" -t 4:0700 -c 4:NOMADE-DATA "$DEV" >/dev/null
fi
# Relecture de la table par le noyau (disque USB ou loop -P)
blockdev --rereadpt "$DEV" 2>/dev/null || { partx -a "$DEV" 2>/dev/null; partx -u "$DEV" 2>/dev/null; } || true
udevadm settle 2>/dev/null || true
P1="$(part "$DEV" 1)" P2="$(part "$DEV" 2)" P3="$(part "$DEV" 3)" P4="$(part "$DEV" 4)"
for p in "$P1" "$P2" "$P3"; do [[ -b "$p" ]] || die "partition $p absente après relecture de la table"; done
unmount_target
log "racine : $(( (p3_end - p3_start + 1) / 2097152 )) Gio"
U3="$(blkid -s UUID -o value "$P3")"          # UUID de la racine de l'image (gardé, E-07)
U2="$(blkid -s UUID -o value "$P2")"
[[ -n "$U3" && -n "$U2" ]] || die "UUID des partitions de l'image introuvables"

# --------------------------------------------------------------------------------------------
LUKS_UUID=""
if [[ "$DEPLOY_ENCRYPT" == 1 ]]; then
  step "Racine LUKS2, clé de volume générée sur la cible (E-30, D-035)"
  # Source : la racine de l'image elle-même, en lecture seule
  ILOOP="$(losetup --show -f -r -P "$IMAGE")"
  udevadm settle 2>/dev/null || true
  [[ -b "${ILOOP}p3" ]] || partx -a "$ILOOP" 2>/dev/null || true
  mount -o ro,noload "${ILOOP}p3" "$SRC"
  # Le clair copié par bmaptool est rendu au SSD avant le chiffrement
  blkdiscard -f "$P3" 2>/dev/null || wipefs -a -q "$P3"
  pbkdf=()
  if [[ "$TEST" == 1 ]]; then pbkdf=(--pbkdf argon2id --pbkdf-memory 65536 --pbkdf-force-iterations 4); fi
  printf '%s' "$PASSPHRASE" | cryptsetup luksFormat --batch-mode --type luks2 --sector-size 4096 \
    --label nomade-luks "${pbkdf[@]}" --key-file - "$P3"
  printf '%s' "$PASSPHRASE" | cryptsetup open --key-file - --persistent --allow-discards \
    --perf-no_read_workqueue --perf-no_write_workqueue "$P3" "$MAPPER"
  OPENED="$MAPPER"
  LUKS_UUID="$(cryptsetup luksUUID "$P3")"
  dump="$(cryptsetup luksDump "$P3")"
  flags="$(awk -F: '/^Flags:/ { gsub(/[[:space:]]+/, " ", $2); print $2 }' <<<"$dump")"
  for f in allow-discards no-read-workqueue no-write-workqueue; do
    [[ " $flags " == *" $f "* ]] || die "drapeau LUKS persistant absent : $f (Flags :$flags)"
  done
  log "LUKS2 $LUKS_UUID, drapeaux persistants :$flags"
  # Même UUID et même étiquette que la racine de l'image : fstab (E-07) et grub.cfg restent valides.
  # Options de création de la cible (son mke2fs.conf), pas celles de la machine qui déploie.
  # -i : un inode pour DEPLOY_INODE_RATIO octets (D-041). Le défaut (16 Kio) donne 62 M d'inodes
  # sur 1 To, soit ≈ 15 Gio de tables que ext4lazyinit écrit au premier démarrage.
  MKE2FS_CONFIG="$SRC/etc/mke2fs.conf" mkfs.ext4 -q -F -i "$DEPLOY_INODE_RATIO" -U "$U3" \
    -L nomade-root "/dev/mapper/$MAPPER"
  mount "/dev/mapper/$MAPPER" "$MNT"
  log "copie de la racine (rsync, attributs étendus et liens durs compris)…"
  rsync -aHAXS --numeric-ids "$SRC/" "$MNT/"
  umount "$SRC"
  losetup -d "$ILOOP"; ILOOP=""
else
  step "Racine en clair agrandie (DEPLOY_ENCRYPT=0)"
  rc=0; e2fsck -f -p "$P3" || rc=$?
  ((rc <= 1)) || die "e2fsck $P3 : code $rc"
  resize2fs "$P3" 2>&1 | tail -n 1 >&2
  mount "$P3" "$MNT"
fi
if ((DEPLOY_DATA_GIB > 0)); then
  mkfs.exfat -L NOMADE-DATA "$P4" >/dev/null
  log "partition de données exFAT NOMADE-DATA : ${DEPLOY_DATA_GIB} Gio"
fi

# --------------------------------------------------------------------------------------------
step "Configuration de la cible en chroot (E-30 à E-33)"
mount "$P2" "$MNT/boot"
mount "$P1" "$MNT/boot/efi"
mount --rbind /dev "$MNT/dev"; mount --make-rslave "$MNT/dev"
mount -t proc proc "$MNT/proc"
mount -t sysfs sysfs "$MNT/sys"            # sans efivarfs : aucune écriture NVRAM possible
mount -t tmpfs -o mode=0755 tmpfs "$MNT/run"
in_target() {
  chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive "$@"
}

if [[ -n "$LUKS_UUID" ]]; then
  cat >"$MNT/etc/crypttab" <<EOF
# zorin-nomade (SPEC E-30) — racine chiffrée, déverrouillée par l'initramfs (clavier belge)
# <nom>      <périphérique>                                  <clé>  <options>
nomade-root  UUID=$LUKS_UUID  none   luks,discard,initramfs
EOF
fi

# E-31 : mot de passe de l'utilisateur (le compte était verrouillé dans l'image)
printf '%s:%s\n' "$TARGET_USER" "$PASSWORD" | in_target chpasswd
[[ "$(in_target passwd -S "$TARGET_USER" | awk '{ print $2 }')" == P ]] || die "compte $TARGET_USER non déverrouillé"
unset PASSWORD

# E-32 : règle udev du pont USB
vid="${VIDPID%:*}" pid="${VIDPID#*:}"
unmap=""
if ((DISCARD_OK)); then
  unmap="ACTION==\"add|change\", SUBSYSTEM==\"scsi_disk\", ATTRS{idVendor}==\"$vid\", ATTRS{idProduct}==\"$pid\", ATTR{provisioning_mode}=\"unmap\""
fi
template="$NOMADE_ROOT/config/templates/60-nomade-usb.rules.in"
rule="$MNT/etc/udev/rules.d/60-nomade-usb.rules"
while IFS= read -r line; do
  line="${line//@VID@/$vid}"; line="${line//@PID@/$pid}"
  if [[ "$line" == @UNMAP_RULE@ ]]; then
    if [[ -n "$unmap" ]]; then line="$unmap"; else line="# (essai de TRIM en échec au déploiement : pas de provisioning_mode)"; fi
  fi
  printf '%s\n' "$line"
done <"$template" >"$rule"
chmod 644 "$rule"
grep -q '@' "$rule" && die "modèle udev incomplètement rempli"

# Trace du déploiement (sans aucun secret)
cat >"$MNT/etc/nomade/deploy-info" <<EOF
# zorin-nomade (SPEC E-33) — écrit au déploiement
DEPLOY_DATE=$(date -Iseconds)
DEPLOY_VERSION=$PROJECT_VERSION
DEPLOY_IMAGE=$(basename "$IMAGE")
DEPLOY_ENCRYPT=$DEPLOY_ENCRYPT
DEPLOY_USB_ID=$VIDPID
DEPLOY_DISCARD=$DISCARD_OK
DEPLOY_DATA_GIB=$DEPLOY_DATA_GIB
DEPLOY_INODE_RATIO=$DEPLOY_INODE_RATIO
DEPLOY_TEST=$TEST
EOF

# E-33 : initramfs (crypttab, clavier belge) et GRUB avec les UUID finaux
in_target update-initramfs -u -k all 2>&1 | grep -vE '^\s*$' | tail -n 5 >&2
for i in "$MNT"/boot/initrd.img-*; do
  content="$(in_target lsinitramfs "/boot/${i##*/}")"
  grep -qx 'etc/console-setup/cached_UTF-8_del.kmap.gz' <<<"$content" \
    || die "${i##*/} sans disposition clavier (D-034)"
  if [[ -n "$LUKS_UUID" ]]; then
    grep -q 'cryptroot/crypttab' <<<"$content" || die "${i##*/} sans cryptroot/crypttab"
  fi
done
udevadm settle 2>/dev/null || true
in_target update-grub 2>&1 | grep -vE '^\s*$' | tail -n 3 >&2
grep -q "root=UUID=$U3" "$MNT/boot/grub/grub.cfg" || die "grub.cfg ne désigne pas la racine par UUID ($U3)"
if grep -qi osprober "$MNT/boot/grub/grub.cfg"; then die "entrée os-prober dans grub.cfg (E-41)"; fi

# Contrôles du chemin amovible (E-09)
E="$MNT/boot/efi/EFI"
[[ -f "$E/BOOT/BOOTX64.EFI" && -f "$E/BOOT/mmx64.efi" ]] || die "chemin amovible incomplet"
cmp -s "$E/BOOT/grubx64.efi" "$E/ubuntu/grubx64.efi" || die "EFI/BOOT/grubx64.efi différent de EFI/ubuntu"
[[ ! -e "$E/BOOT/fbx64.efi" && ! -e "$E/BOOT/BOOTX64.CSV" ]] || die "fbx64.efi ou BOOTX64.CSV dans EFI/BOOT"
grep -q "search.fs_uuid $U2 " "$E/BOOT/grub.cfg" || die "EFI/BOOT/grub.cfg ne renvoie pas vers /boot"

# --------------------------------------------------------------------------------------------
step "Démontage et contrôles finaux (E-33)"
sync
umount -R "$MNT"
for d in "$P2" ${OPENED:+"/dev/mapper/$OPENED"}; do
  e2fsck -f -n "$d" >/dev/null 2>&1 || die "e2fsck $d : erreurs"
done
if [[ -z "$OPENED" ]]; then e2fsck -f -n "$P3" >/dev/null 2>&1 || die "e2fsck $P3 : erreurs"; fi
fsck.vfat -n "$P1" >/dev/null || die "fsck.vfat $P1 : erreurs"
if [[ -n "$OPENED" ]]; then cryptsetup close "$OPENED"; OPENED=""; fi
sync
log "contrôles : systèmes de fichiers sains, chemin amovible présent"
if [[ -n "$TLOOP" ]]; then losetup -d "$TLOOP"; TLOOP=""; fi
log "Déploiement terminé en $(((SECONDS - T0) / 60)) min $(((SECONDS - T0) % 60)) s"

# --------------------------------------------------------------------------------------------
cat >&2 <<EOF

  ────────────────────────────────────────────────────────────────────────────────────────────
  Clé prête. Premier démarrage natif (détail dans docs/premier-demarrage.md) :
   1. Débrancher la clé proprement, la brancher sur un port USB 3, menu de démarrage du PC
      (F12/F9/Échap…), choisir l'entrée USB/UEFI de la clé.
   2. Menu GRUB 3 s, puis phrase de passe LUKS (clavier belge)$( [[ "$DEPLOY_ENCRYPT" == 1 ]] || echo ' — sans objet ici' ).
   3. Connexion en « $TARGET_USER » avec le mot de passe choisi ; Wi-Fi, son, écran.
   4. Contrôles : lsusb -t (uas), lsblk --discard, sudo fstrim -v /, swapon, psd p,
      journalctl -k | grep -i uas_eh, cat /etc/nomade/deploy-info.
   5. Essayer un PC avec Secure Boot actif et un PC sans.
  ────────────────────────────────────────────────────────────────────────────────────────────
EOF
