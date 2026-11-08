#!/usr/bin/env bash
# Vérifie, sans root et sans rien écrire, que les garde-fous de lib.sh refusent ce qu'ils doivent
# refuser (CLAUDE.md, règle 5 ; SPEC E-28). Exécuté par « make ci » (localement et en CI).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
host_guard

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/cible.img"
fails=0

# attendu <ok|refus> <libellé> <commande…> : la commande tourne dans un sous-shell (die y sort)
attendu() {
  local want="$1" label="$2" rc=0; shift 2
  (trap - ERR; "$@") >/dev/null 2>&1 </dev/null || rc=$?
  if [[ "$want" == ok && $rc -eq 0 ]] || [[ "$want" == refus && $rc -ne 0 ]]; then
    printf '  ok     %s\n' "$label"
  else
    printf '  ÉCHEC  %s (code %s, attendu : %s)\n' "$label" "$rc" "$want"
    fails=$((fails + 1))
  fi
}
avec_test() { DEPLOY_TEST=1 "$@"; }

log "assert_test_target"
attendu refus "fichier refusé sans DEPLOY_TEST=1" env -u DEPLOY_TEST bash -c \
  "source '$NOMADE_ROOT/scripts/lib.sh'; assert_test_target '$tmp/cible.img'"
attendu ok    "fichier ordinaire accepté avec DEPLOY_TEST=1" avec_test assert_test_target "$tmp/cible.img"
attendu refus "cible vide refusée" avec_test assert_test_target ""
attendu refus "disque réel refusé (/dev/sda)" avec_test assert_test_target /dev/sda
attendu refus "périphérique non loop refusé (/dev/null)" avec_test assert_test_target /dev/null
attendu refus "loop inexistant refusé" avec_test assert_test_target /dev/loop999
attendu refus "dossier refusé" avec_test assert_test_target "$tmp"

log "assert_real_usb_target"
attendu refus "cible vide refusée" assert_real_usb_target ""
attendu refus "chemin /dev/sdX refusé (by-id/usb-* exigé)" assert_real_usb_target /dev/sda
attendu refus "chemin by-id non USB refusé" assert_real_usb_target /dev/disk/by-id/ata-DISQUE
attendu refus "partition refusée" assert_real_usb_target /dev/disk/by-id/usb-SSK_X-0:0-part1
attendu refus "périphérique absent refusé" assert_real_usb_target /dev/disk/by-id/usb-INEXISTANT-0:0
attendu refus "fichier refusé" assert_real_usb_target "$tmp/cible.img"
# Confirmation interactive : sans terminal, même une vraie clé serait refusée
attendu refus "sans terminal, refus (entrée standard fermée)" assert_real_usb_target \
  "$(find /dev/disk/by-id/ -name 'usb-*' ! -name '*-part*' 2>/dev/null | head -n1)"

log "assert_usb_disk (lecture seule, diag-cle)"
attendu refus "cible vide refusée" assert_usb_disk ""
attendu refus "chemin /dev/sdX refusé (by-id/usb-* exigé)" assert_usb_disk /dev/sda
attendu refus "chemin by-id non USB refusé" assert_usb_disk /dev/disk/by-id/ata-DISQUE
attendu refus "partition refusée" assert_usb_disk /dev/disk/by-id/usb-SSK_X-0:0-part1
attendu refus "périphérique absent refusé" assert_usb_disk /dev/disk/by-id/usb-INEXISTANT-0:0
attendu refus "fichier refusé" assert_usb_disk "$tmp/cible.img"
attendu refus "diag-cle.sh : fichier refusé hors mode test" env -u DEPLOY_TEST "$NOMADE_ROOT/scripts/diag-cle.sh" \
  --cible "$tmp/cible.img"
attendu refus "diag-cle.sh --complet refusé sans root" "$NOMADE_ROOT/scripts/diag-cle.sh" --complet \
  --cible /dev/disk/by-id/usb-INEXISTANT-0:0
attendu refus "make diag-cle sans KEY refusé" make -s -C "$NOMADE_ROOT" diag-cle

# vaut <attendu> <libellé> <commande…> : compare la sortie standard
vaut() {
  local want="$1" label="$2" got rc=0; shift 2
  got="$( (trap - ERR; "$@") 2>/dev/null </dev/null)" || rc=$?
  if [[ $rc -eq 0 && "$got" == "$want" ]]; then printf '  ok     %s\n' "$label"
  else printf '  ÉCHEC  %s (obtenu : %s, code %s ; attendu : %s)\n' "$label" "$got" "$rc" "$want"; fails=$((fails + 1)); fi
}
# dg <taille_gio> [VAR=valeur…] : data_gib après load_env (les surcharges passent après, comme local.env)
# shellcheck disable=SC2016  # le script est évalué par le bash enfant
dg() { bash -c 'source "$0"; load_env; for a in "${@:2}"; do export "${a?}"; done; data_gib "$1"' \
  "$NOMADE_ROOT/scripts/lib.sh" "$@"; }
log "data_gib : taille de NOMADE-DATA (D-046)"
vaut 8   "fichier de test de 64 Gio : plancher de 8 Gio" dg 64 DEPLOY_DATA_GIB=
vaut 11  "clé de 128 Go (119 Gio) : 10 %" dg 119 DEPLOY_DATA_GIB=
vaut 93  "clé de 1 To (931 Gio) : 10 %" dg 931 DEPLOY_DATA_GIB=
vaut 0   "clé de 40 Gio : racine trop petite, pas de partition" dg 40 DEPLOY_DATA_GIB=
vaut 8   "clé de 51 Gio : racine de 40 Gio, partition au plancher" dg 51 DEPLOY_DATA_GIB=
vaut 0   "DEPLOY_DATA_GIB=0 : aucune partition" dg 931 DEPLOY_DATA_GIB=0
vaut 20  "DEPLOY_DATA_GIB=20 : taille imposée" dg 119 DEPLOY_DATA_GIB=20
vaut 0   "DEPLOY_DATA_PCT=0 : aucune partition" dg 931 DEPLOY_DATA_GIB= DEPLOY_DATA_PCT=0
attendu refus "DEPLOY_DATA_GIB non numérique refusé" dg 119 DEPLOY_DATA_GIB=dix
attendu refus "DEPLOY_DATA_PCT > 50 refusé" dg 119 DEPLOY_DATA_GIB= DEPLOY_DATA_PCT=80

log "scripts de déploiement"
attendu refus "deploy.sh refuse de tourner sans root" "$NOMADE_ROOT/scripts/deploy.sh" --target /dev/sda
attendu refus "make deploy refuse sans root" make -s -C "$NOMADE_ROOT" deploy KEY=/dev/sda

((fails == 0)) || die "$fails garde-fou(s) défaillant(s)"
log "garde-fous : tous les refus attendus ont eu lieu"
