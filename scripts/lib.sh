#!/usr/bin/env bash
# Bibliothèque commune. À sourcer en tête de chaque script :
#   # shellcheck source=lib.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set -Eeuo pipefail
shopt -s inherit_errexit

NOMADE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NOMADE_ROOT
CACHE_DIR="$NOMADE_ROOT/cache"
OUT_DIR="$NOMADE_ROOT/out"
BUILDER_DIR="$NOMADE_ROOT/.builder"
export CACHE_DIR OUT_DIR BUILDER_DIR

# --- Journalisation -------------------------------------------------------------
_color() { if [[ -t 2 ]]; then printf '\033[%sm' "$1"; fi; }
log()  { printf '%s[%s]%s %s\n' "$(_color '1;34')" "$(date +%H:%M:%S)" "$(_color 0)" "$*" >&2; }
warn() { printf '%sATTENTION%s %s\n' "$(_color '1;33')" "$(_color 0)" "$*" >&2; }
die()  { printf '%sERREUR%s %s\n' "$(_color '1;31')" "$(_color 0)" "$*" >&2; exit 1; }

# shellcheck disable=SC2154  # rc est affecté dans le piège lui-même
trap 'rc=$?; printf "ERREUR ligne %s (%s) : code %s\n" "$LINENO" "${BASH_COMMAND}" "$rc" >&2' ERR

# --- Utilitaires --------------------------------------------------------------
require_cmd() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "commande(s) manquante(s) : ${missing[*]} (voir README, section 1)"
}

# Charge config/project.env, config/iso.env puis config/local.env (surcharges non versionnées).
load_env() {
  local f
  for f in "$NOMADE_ROOT/config/project.env" "$NOMADE_ROOT/config/iso.env" \
           "$NOMADE_ROOT/config/local.env"; do
    # shellcheck disable=SC1090
    if [[ -f "$f" ]]; then source "$f"; fi
  done
}

# Les scripts « hôte » ne doivent jamais tourner en root.
host_guard() {
  [[ $EUID -ne 0 ]] || die "ce script s'exécute sur l'hôte SANS privilèges (pas de sudo)"
}

# --- Garde-fous des cibles de déploiement ---------------------------------------
# À appeler dans TOUT script qui écrit sur une cible. Ne pas affaiblir.

# Disques portant les systèmes de fichiers montés de l'hôte (/, /boot, /boot/efi, /home).
_system_disks() {
  local mp src
  for mp in / /boot /boot/efi /home; do
    src="$(findmnt -no SOURCE "$mp" 2>/dev/null || true)"
    [[ -n "$src" && -e "$src" ]] || continue
    lsblk -nsro NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1 }'
  done | sort -u
}

# Cible réelle : la clé USB de Fabien. Exige une confirmation par saisie du numéro de série.
assert_real_usb_target() {
  local target="${1:-}" dev name tran model serial size answer
  [[ -n "$target" ]] || die "aucune cible (KEY=/dev/disk/by-id/usb-…)"
  [[ "$target" == /dev/disk/by-id/usb-* ]] \
    || die "la cible doit être un chemin /dev/disk/by-id/usb-* (reçu : $target)"
  [[ "$target" != *-part[0-9]* ]] || die "la cible doit être le disque entier, pas une partition"
  [[ -b "$target" ]] || die "périphérique bloc introuvable : $target"

  dev="$(readlink -f "$target")"
  name="$(basename "$dev")"
  [[ "$(lsblk -dno TYPE "$dev")" == disk ]] || die "$dev n'est pas un disque"
  tran="$(lsblk -dno TRAN "$dev" | tr -d ' ')"
  [[ "$tran" == usb ]] || die "$dev n'est pas sur un bus USB (transport : ${tran:-inconnu})"
  if _system_disks | grep -qx "$name"; then
    die "$dev porte un système de fichiers de l'hôte — refus"
  fi
  if lsblk -nro MOUNTPOINT "$dev" | grep -q .; then
    die "$dev (ou une de ses partitions) est monté — démonte-le d'abord"
  fi

  model="$(lsblk -dno MODEL "$dev" | sed 's/[[:space:]]*$//')"
  serial="$(lsblk -dno SERIAL "$dev" | tr -d ' ')"
  size="$(lsblk -dno SIZE "$dev" | tr -d ' ')"
  [[ -n "$serial" ]] || die "numéro de série vide pour $dev : confirmation impossible"

  printf '\n  Cible   : %s\n  Disque  : %s\n  Modèle  : %s\n  Série   : %s\n  Taille  : %s\n\n' \
    "$target" "$dev" "${model:-?}" "$serial" "$size" >&2
  [[ -t 0 ]] || die "confirmation interactive requise (terminal)"
  read -r -p "TOUT le contenu de ce disque sera détruit. Tape son numéro de série pour confirmer : " answer
  [[ "$answer" == "$serial" ]] || die "confirmation incorrecte — abandon, rien n'a été écrit"
  log "Cible confirmée : $dev"
}

# Cible de test : fichier ordinaire ou loop device, uniquement avec DEPLOY_TEST=1.
assert_test_target() {
  local target="${1:-}" backing
  [[ "${DEPLOY_TEST:-0}" == 1 ]] || die "assert_test_target exige DEPLOY_TEST=1"
  [[ -n "$target" ]] || die "aucune cible de test"
  if [[ -f "$target" ]]; then
    :
  elif [[ "$target" =~ ^/dev/loop[0-9]+$ && -b "$target" ]]; then
    backing="$(losetup -nO BACK-FILE "$target" 2>/dev/null | sed 's/[[:space:]]*$//')"
    [[ -n "$backing" && -f "$backing" ]] || die "$target n'est adossé à aucun fichier"
  else
    die "cible de test refusée : $target (fichier ordinaire ou /dev/loopN uniquement)"
  fi
  log "Cible de test : $target"
}
