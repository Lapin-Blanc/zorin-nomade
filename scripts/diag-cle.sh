#!/usr/bin/env bash
# Diagnostic d'une clé AVANT le déploiement, depuis l'hôte (SPEC E-45, D-048).
#
#   make diag-cle KEY=/dev/disk/by-id/usb-…              identification seule (sans root)
#   sudo make diag-cle KEY=/dev/disk/by-id/usb-…         + SMART et lectures directes : rien n'est écrit
#   sudo make diag-cle KEY=… COMPLET=1 [DUREE=1]         analyse complète : EFFACE la clé
#   Test (Claude, VM de build uniquement) :
#     DEPLOY_TEST=1 scripts/diag-cle.sh --cible <fichier|/dev/loopN> [--complet] --sortie <dossier>
#
# Garde-fous (CLAUDE.md, règle 5) : lecture seule → assert_usb_disk ; analyse complète →
# assert_real_usb_target (numéro de série à taper), comme deploy.sh ; test → assert_test_target.
# Le diagnostic lui-même est en Python (config/rootfs/usr/local/lib/nomade/nomade_diag, D-047).
# Rapport : diagnostics/archives/diag-cle-<date>-<VID-PID>-<empreinte>.tar.zst (anonymisé, D-049).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd python3 zstd lsblk udevadm

CIBLE="" COMPLET=0 DUREE=1 BRUT=0 SORTIE="$NOMADE_ROOT/diagnostics/archives"
while (($#)); do
  case "$1" in
    --cible) CIBLE="${2:?}"; shift 2 ;;
    --complet) COMPLET=1; shift ;;
    --duree) DUREE="${2:?}"; shift 2 ;;
    --brut) BRUT=1; shift ;;
    --sortie) SORTIE="${2:?}"; shift 2 ;;
    *) die "option inconnue : $1" ;;
  esac
done
[[ "$DUREE" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "DUREE en minutes (ex. 1, 3, 0.5) : $DUREE"
TEST="${DEPLOY_TEST:-0}"
LOOP="" UDEV_RULE=""
cleanup() {
  local rc=$?
  set +e
  if [[ -n "$LOOP" ]]; then losetup -d "$LOOP"; fi
  if [[ -n "$UDEV_RULE" ]]; then rm -f "$UDEV_RULE"; udevadm control --reload 2>/dev/null; fi
  exit "$rc"
}
trap cleanup EXIT

if [[ "$TEST" == 1 ]]; then
  [[ $EUID -eq 0 ]] || die "mode test : en root, dans la VM de build"
  assert_test_target "$CIBLE"
  if [[ -f "$CIBLE" ]]; then
    if ((COMPLET)); then LOOP="$(losetup --show -f "$CIBLE")"; else LOOP="$(losetup --show -f -r "$CIBLE")"; fi
    DEV="$LOOP"
  else
    DEV="$CIBLE"
  fi
elif ((COMPLET)); then
  [[ $EUID -eq 0 ]] || die "analyse complète : sudo make diag-cle KEY=… COMPLET=1"
  log "ANALYSE COMPLÈTE : toute la clé sera effacée (capacité réelle, écritures, cache SLC)."
  assert_real_usb_target "$CIBLE"
  DEV="$(readlink -f "$CIBLE")"
  # GNOME ne doit rien monter pendant l'analyse (règle temporaire, comme deploy.sh)
  UDEV_RULE=/run/udev/rules.d/99-nomade-diag-noauto.rules
  mkdir -p /run/udev/rules.d
  printf 'SUBSYSTEM=="block", KERNEL=="%s*", ENV{UDISKS_IGNORE}="1"\n' "$(basename "$DEV")" >"$UDEV_RULE"
  udevadm control --reload
else
  assert_usb_disk "$CIBLE"
  DEV="$(readlink -f "$CIBLE")"
fi

if ((COMPLET)); then MODE=complet; elif [[ $EUID -eq 0 ]]; then MODE=lecture; else MODE=identification; fi
OWNER_UID="${SUDO_UID:-$(id -u)}" OWNER_GID="${SUDO_GID:-$(id -g)}"
OWNER_NAME="${SUDO_USER:-$(id -un)}"
# diagnostics/ (sel, archives) appartient à l'appelant de sudo, jamais à root
install -d -o "$OWNER_UID" -g "$OWNER_GID" "$NOMADE_ROOT/diagnostics" "$SORTIE"
SEL="$NOMADE_ROOT/diagnostics/.sel"
# Taille minimale d'une clé : image (ESP + /boot + racine) + 4 Gio de marge, comme deploy.sh
TAILLE_MIN=$(( (IMAGE_ESP_MIB + IMAGE_BOOT_MIB + 1023) / 1024 + IMAGE_ROOT_GIB + 4 ))
log "diag-cle $PROJECT_VERSION : mode $MODE, $DEV"
args=(cle --disque "$DEV" --mode "$MODE" --duree-min "$DUREE" --sel "$SEL" --sortie "$SORTIE"
      --version "$PROJECT_VERSION" --taille-min-gio "$TAILLE_MIN" --cache "$CIBLE"
      --uid "$OWNER_UID" --gid "$OWNER_GID")
if [[ "$OWNER_NAME" != root ]]; then args+=(--utilisateur "$OWNER_NAME"); fi
if ((BRUT)); then args+=(--brut); fi
python3 -I -B "$NOMADE_ROOT/config/rootfs/usr/local/lib/nomade/diag.py" "${args[@]}"
