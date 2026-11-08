#!/usr/bin/env bash
# Essais de diag-cle (SPEC E-45) DANS LA VM DE BUILD, en root ; lancé par scripts/diag-cle-test.sh.
# Jamais sur un vrai périphérique : fichiers creux, loop devices et une table device-mapper.
#   1. lecture seule sur un fichier : le fichier est inchangé (SHA-256) ;
#   2. analyse complète sur un fichier sain : capacité conforme, TRIM, clé vide à la fin ;
#   3. analyse complète d'une contrefaçon simulée (1 Gio annoncé, 512 Mio réels, adresses
#      repliées par device-mapper) : repliement détecté, verdict « ne pas déployer » ;
#   4. refus des garde-fous hors mode test.
# Les chiffres mesurés dans la VM n'ont pas de sens : seuls le déroulement et le résumé comptent.
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
load_env
[[ $EUID -eq 0 ]] || die "à lancer en root dans la VM de build"
require_cmd python3 zstd losetup dmsetup blkdiscard sha256sum

W=/work/diag-test
D="$NOMADE_ROOT/scripts/diag-cle.sh"
LIB="$NOMADE_ROOT/config/rootfs/usr/local/lib/nomade"
FAUX=nomade-diag-faux
FLOOP=""
fin() {
  set +e
  trap - ERR
  dmsetup remove "$FAUX" 2>/dev/null
  if [[ -n "$FLOOP" ]]; then losetup -d "$FLOOP"; fi
}
trap fin EXIT
dmsetup remove "$FAUX" 2>/dev/null || true
rm -rf "$W"
mkdir -p "$W/out"
fails=0
ok() { printf 'DIAG-CLE-TEST: ok     %s\n' "$*"; }
ko() { printf 'DIAG-CLE-TEST: ÉCHEC  %s\n' "$*"; fails=$((fails + 1)); }
# vaut <libellé> <attendu> <valeur> ; champ <archive> <clé.pointée> : valeur JSON du résumé
vaut() { if [[ "$3" == "$2" ]]; then ok "$1"; else ko "$1 (obtenu : $3, attendu : $2)"; fi; }
si() { local l="$1"; shift; if "$@"; then ok "$l"; else ko "$l"; fi; }   # si <libellé> <commande…>
operations() { [[ "$(champ "$1" lecture.aleatoire_8.operations)" =~ ^[1-9][0-9]*$ ]]; }
champ() {
  python3 -I -B -c 'import json, sys
sys.path.insert(0, sys.argv[1])
from nomade_diag import archive
v = archive.lire_resume(sys.argv[2])
for k in sys.argv[3].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print(json.dumps(v, ensure_ascii=False))' "$LIB" "$1" "$2"
}
derniere() { find "$W/out" -name '*.tar.zst' -printf '%T@ %p\n' | sort -n | tail -n1 | cut -d' ' -f2; }
zeros_mio() {   # zeros_mio <fichier> <décalage en Mio> : ce Mio ne contient que des zéros
  cmp -s -n 1048576 <(dd if="$1" bs=1M skip="$2" count=1 status=none) /dev/zero
}

log "1. lecture seule sur un fichier de 1 Gio"
truncate -s 1G "$W/cle.img"
dd if=/dev/urandom of="$W/cle.img" bs=1M count=64 seek=100 conv=notrunc status=none
h1="$(sha256sum <"$W/cle.img")"
if DEPLOY_TEST=1 "$D" --cible "$W/cle.img" --sortie "$W/out" >"$W/t1.txt" 2>&1; then ok "diag-cle en lecture seule"
else ko "diag-cle en lecture seule"; tail -n 20 "$W/t1.txt"; fi
vaut "lecture seule : fichier inchangé" "$h1" "$(sha256sum <"$W/cle.img")"
a="$(derniere)"
vaut "lecture seule : mode" '"lecture"' "$(champ "$a" options.mode)"
vaut "lecture seule : pas d'analyse" null "$(champ "$a" analyse)"
vaut "lecture seule : anonymisé" true "$(champ "$a" anonymise)"
vaut "lecture seule : schéma 1, type cle" '1 "cle"' "$(champ "$a" schema) $(champ "$a" type)"
si "lecture seule : lectures parallèles mesurées" operations "$a"

log "2. analyse complète sur un fichier sain"
if DEPLOY_TEST=1 "$D" --cible "$W/cle.img" --complet --duree 0.1 --sortie "$W/out" >"$W/t2.txt" 2>&1; then
  ok "diag-cle complet"
else ko "diag-cle complet"; tail -n 20 "$W/t2.txt"; fi
a="$(derniere)"
vaut "complet : capacité conforme" true "$(champ "$a" analyse.capacite.conforme)"
vaut "complet : pas de repliement" false "$(champ "$a" analyse.capacite.repliement)"
vaut "complet : TRIM réel" true "$(champ "$a" analyse.trim_reel)"
vaut "complet : catégorie mesurée" '"mesuree"' "$(champ "$a" verdict.certitude)"
vaut "complet : 1 Gio, trop petite pour l'image" false "$(champ "$a" verdict.deployable)"
si "complet : premier Mio à zéro" zeros_mio "$W/cle.img" 0
si "complet : dernier Mio à zéro" zeros_mio "$W/cle.img" 1023

log "3. contrefaçon simulée : 1 Gio annoncé, 512 Mio réels"
truncate -s 512M "$W/faux.img"
FLOOP="$(losetup --show -f "$W/faux.img")"
printf '0 1048576 linear %s 0\n1048576 1048576 linear %s 0\n' "$FLOOP" "$FLOOP" | dmsetup create "$FAUX"
if python3 -I -B "$LIB/diag.py" cle --disque "/dev/mapper/$FAUX" --mode complet --duree-min 0.1 \
     --sel "$W/.sel" --sortie "$W/out" --version test >"$W/t3.txt" 2>&1; then ok "analyse de la contrefaçon"
else ko "analyse de la contrefaçon"; tail -n 20 "$W/t3.txt"; fi
a="$(derniere)"
vaut "contrefaçon : capacité non conforme" false "$(champ "$a" analyse.capacite.conforme)"
vaut "contrefaçon : repliement détecté" true "$(champ "$a" analyse.capacite.repliement)"
vaut "contrefaçon : verdict" '"contrefacon"' "$(champ "$a" verdict.categorie)"
vaut "contrefaçon : ne pas déployer" false "$(champ "$a" verdict.deployable)"
dmsetup remove "$FAUX"; losetup -d "$FLOOP"; FLOOP=""

log "4. garde-fous hors mode test"
refus() {
  local label="$1"; shift
  if (trap - ERR; env -u DEPLOY_TEST "$@") >/dev/null 2>&1 </dev/null; then ko "refus attendu : $label"
  else ok "refus : $label"; fi
}
refus "fichier sans DEPLOY_TEST=1" "$D" --cible "$W/cle.img"
refus "loop sans DEPLOY_TEST=1" "$D" --cible /dev/loop0
refus "disque de la VM (lecture)" "$D" --cible /dev/vda
refus "disque de la VM (complet)" "$D" --cible /dev/vda --complet
refus "by-id non USB" "$D" --cible "$(find /dev/disk/by-id/ -mindepth 1 | head -n1)"

rm -f "$W/cle.img" "$W/faux.img"
if ((fails == 0)); then echo "DIAG-CLE-TEST: RESULT=PASS"; else echo "DIAG-CLE-TEST: RESULT=FAIL ($fails)"; exit 1; fi
