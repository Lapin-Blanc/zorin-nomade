#!/usr/bin/env bash
# Test complet du déploiement chiffré (SPEC E-37). Hôte, SANS root.
#
#   deploy-test.sh [--image out/latest.img] [--runs 1|2] [--sb on|off|both]
#
# 1. Envoie le dépôt et l'image dans la VM de build ;
# 2. y exécute scripts/deploy.sh en mode test (DEPLOY_TEST=1) vers un fichier creux de
#    DEPLOY_TEST_SIZE_GIB Gio, avec le VID:PID du usb-storage de QEMU (46f4:0001) ; --runs 2
#    déploie deux fois de suite sur le même fichier (E-34 : rejouable) ;
# 3. rapatrie le fichier (creux) dans out/deploy-test/ et arrête la VM de build ;
# 4. le démarre dans QEMU : la phrase est tapée au clavier virtuel quand la question est à
#    l'écran, puis l'autotest vérifie le déploiement (fw_cfg opt/nomade/deployed=1).
#
# La phrase de passe et le mot de passe sont générés ici, à chaque exécution, transmis par des
# tubes (entrée standard) et jamais écrits : ni dans la cible, ni dans un journal, ni sur disque.
# Phrase : lettres minuscules, dont « a », « z » et « m » (placées autrement en AZERTY et en
# QWERTY) : le harnais tape les touches d'un clavier belge, la phrase n'est acceptée que si
# l'initramfs utilise bien la disposition « be » (E-30).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
host_guard
load_env
require_cmd ssh tar zstd

S="$NOMADE_ROOT/scripts"
image="$OUT_DIR/latest.img" runs=1 sb=both
while (($#)); do
  case "$1" in
    --image) image="${2:?}"; shift 2 ;;
    --runs) runs="${2:?}"; shift 2 ;;
    --sb) sb="${2:?}"; shift 2 ;;
    *) die "option inconnue : $1" ;;
  esac
done
image="$(readlink -f "$image")"
name="$(basename "$image" .img)"
[[ -f "$image" && -f "${image%.img}.bmap" ]] || die "image ou bmap introuvable : $image (make image)"
[[ "$runs" =~ ^[12]$ ]] || die "--runs attend 1 ou 2"
stamp="$(date +%Y%m%d-%H%M)"
logf="$OUT_DIR/logs/deploy-test-$stamp.log"
dest="$OUT_DIR/deploy-test"
mkdir -p "$OUT_DIR/logs" "$dest"
vm() { "$S/bssh" "$@"; }

# Secrets du test : en mémoire uniquement
gen() { LC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2" || true; }
PASSPHRASE="azm$(gen 'a-z' 17)"
PASSWORD="$(gen 'A-Za-z0-9' 24)"
[[ ${#PASSPHRASE} -eq 20 && ${#PASSWORD} -eq 24 ]] || die "génération des secrets de test impossible"

# Place sur l'hôte : le fichier rapatrié n'occupe que les blocs écrits (≈ taille de l'image)
need_gb=$(( $(du -B1G "$image" | cut -f1) + 10 ))
free_gb="$(df -BG --output=avail "$OUT_DIR" | tail -n1 | tr -dc 0-9)"
((free_gb >= need_gb)) || die "espace insuffisant sur l'hôte : ${free_gb} Gio libres, ${need_gb} nécessaires"

"$S/builder.sh" up
log "Envoi des scripts et de la configuration…"
tar -C "$NOMADE_ROOT" -cf - scripts config \
  | vm 'rm -rf /work/repo && mkdir -p /work/repo && tar -C /work/repo -xf -'
if vm "test -f /work/img/$name.img && cd /work/img && sha256sum -c --quiet $name.sha256" 2>/dev/null; then
  log "image déjà présente dans la VM"
else
  log "Envoi de l'image $name dans la VM (fichier creux, flux zstd)…"
  vm 'sudo rm -rf /work/img && mkdir -p /work/img'
  tar -C "$(dirname "$image")" -cSf - "$name.img" "$name.bmap" "$name.sha256" | zstd -1 -T0 -q \
    | vm 'zstd -dcq | tar -C /work/img -xSf -'
  vm "cd /work/img && sha256sum -c --quiet $name.sha256" || die "image corrompue pendant l'envoi"
fi

vm "sudo rm -rf /work/deploy-test && mkdir -p /work/deploy-test \
    && truncate -s ${DEPLOY_TEST_SIZE_GIB}G /work/deploy-test/stick.img"
for ((i = 1; i <= runs; i++)); do
  log "Déploiement $i/$runs dans la VM — journal : ${logf#"$NOMADE_ROOT"/}"
  if ! printf '%s\n%s\n' "$PASSPHRASE" "$PASSWORD" \
       | vm "sudo env DEPLOY_TEST=1 /work/repo/scripts/deploy.sh --target /work/deploy-test/stick.img \
               --image /work/img/$name.img --usb-id 46f4:0001 --secrets-stdin" >>"$logf" 2>&1; then
    tail -n 25 "$logf" >&2
    die "échec du déploiement de test — journal : $logf"
  fi
  grep -aE '^\[[0-9:]+\] ===|TRIM|LUKS2|Déploiement terminé' "$logf" | tail -n 4 >&2
done
# Le journal ne doit contenir aucun secret
if grep -aqF -e "$PASSPHRASE" -e "$PASSWORD" "$logf"; then die "un secret de test apparaît dans $logf"; fi

log "Rapatriement du fichier déployé (creux)…"
rm -f "$dest/stick.img"
vm "cd /work/deploy-test && tar -cSf - stick.img | zstd -1 -T0 -q" | zstd -dcq | tar -C "$dest" -xSf -
vm 'sudo rm -rf /work/deploy-test; sudo fstrim / >/dev/null 2>&1 || true'
log "fichier : $(du -h "$dest/stick.img" | cut -f1) alloués / $(du -h --apparent-size "$dest/stick.img" | cut -f1)"
"$S/builder.sh" down

log "Démarrage du fichier déployé (déverrouillage au clavier virtuel)"
NOMADE_TEST_PASSPHRASE="$PASSPHRASE" "$S/test-image.sh" --image "$dest/stick.img" --encrypted \
  --sb "$sb" --name deploy
