#!/usr/bin/env bash
# Construit l'image dans la VM de build et la rapatrie dans out/ (SPEC E-05, D-017).
# Hôte, SANS root : ce script ne fait qu'orchestrer ; le travail root est fait par
# scripts/vm/build.sh dans la VM (le même script tourne tel quel sur un runner CI).
#
#   build-image.sh
#
# Étapes : ISO vérifiée → VM démarrée → envoi des scripts/config (et de l'ISO si besoin) →
# construction → rapatriement creux → out/zorin-nomade-<AAAAMMJJ-HHMM>.{img,bmap,manifest,sha256}
# et out/latest.img. Journal complet : out/logs/build-<AAAAMMJJ-HHMM>.log (le terminal n'en montre
# que les étapes).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
host_guard
load_env
require_cmd ssh tar zstd sha256sum git

S="$NOMADE_ROOT/scripts"
stamp="$(date +%Y%m%d-%H%M)"
name="$PROJECT_NAME-$stamp"
logf="$OUT_DIR/logs/build-$stamp.log"
mkdir -p "$OUT_DIR/logs"
commit="$(git -C "$NOMADE_ROOT" rev-parse --short HEAD 2>/dev/null || echo inconnu)"
if ! git -C "$NOMADE_ROOT" diff --quiet HEAD -- scripts config 2>/dev/null; then commit+="+modifs"; fi
vm() { "$S/bssh" "$@"; }

iso="$("$S/fetch-iso.sh")"
"$S/builder.sh" up

vm_iso="/work/iso/$(basename "$iso")"
if vm "echo '${ISO_SHA256,,}  $vm_iso' | sha256sum -c --quiet - >/dev/null 2>&1"; then
  log "ISO déjà présente dans la VM"
else
  log "Envoi de l'ISO dans la VM…"
  vm "rm -f '$vm_iso'"
  "$S/builder.sh" push "$iso" /work/iso
fi

log "Envoi des scripts et de la configuration (commit $commit)…"
tar -C "$NOMADE_ROOT" -cf - scripts config \
  | vm 'rm -rf /work/repo && mkdir -p /work/repo && tar -C /work/repo -xf -'
vm 'sudo rm -rf /work/out && mkdir -p /work/out /work/cache/apt'

log "Construction dans la VM — journal : ${logf#"$NOMADE_ROOT"/}"
if ! vm "sudo /work/repo/scripts/vm/build.sh --iso '$vm_iso' --out /work/out \
           --cache /work/cache/apt --stamp '$stamp' --commit '$commit'" 2>&1 \
     | tee "$logf" | grep --line-buffered -E '^\[[0-9:]+\]|ATTENTION|ERREUR' >&2; then
  tail -n 25 "$logf" >&2
  die "échec de la construction — journal complet : $logf"
fi

log "Rapatriement de l'image (fichier creux, flux zstd)…"
vm "cd /work/out && tar -cSf - '$name.img' '$name.bmap' '$name.manifest' '$name.sha256' | zstd -1 -T0 -q" \
  | zstd -dcq | tar -C "$OUT_DIR" -xSf -
(cd "$OUT_DIR" && sha256sum -c --quiet "$name.sha256") || die "empreinte de l'image rapatriée incorrecte"
ln -sfn "$name.img" "$OUT_DIR/latest.img"
vm 'sudo rm -rf /work/out; sudo fstrim / >/dev/null 2>&1 || true'

# Les anciennes images (plusieurs Gio chacune) ne sont pas gardées indéfiniment.
mapfile -t old < <(find "$OUT_DIR" -maxdepth 1 -name "$PROJECT_NAME-*.img" -printf '%T@ %p\n' \
                    | sort -rn | tail -n +"$((KEEP_IMAGES + 1))" | cut -d' ' -f2-)
for o in "${old[@]}"; do
  rm -f "$o" "${o%.img}.bmap" "${o%.img}.manifest" "${o%.img}.sha256"
  log "ancienne image supprimée : $(basename "$o")"
done

log "Image : out/$name.img ($(du -h "$OUT_DIR/$name.img" | cut -f1) alloués, $(du -h --apparent-size "$OUT_DIR/$name.img" | cut -f1) apparents) → out/latest.img"
