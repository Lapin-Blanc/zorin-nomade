#!/usr/bin/env bash
# Essai de diag-cle dans la VM de build (SPEC E-45). Hôte, SANS root : envoie scripts/ et config/
# dans la VM et y lance scripts/vm/diag-cle-test-vm.sh (fichiers, loop, contrefaçon simulée).
# Journal : out/logs/diag-cle-test-<date>.log.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
host_guard
load_env
require_cmd ssh tar

S="$NOMADE_ROOT/scripts"
logf="$OUT_DIR/logs/diag-cle-test-$(date +%Y%m%d-%H%M).log"
mkdir -p "$OUT_DIR/logs"
"$S/builder.sh" up
log "Envoi des scripts et de la configuration…"
tar -C "$NOMADE_ROOT" --exclude=__pycache__ -cf - scripts config \
  | "$S/bssh" 'rm -rf /work/repo && mkdir -p /work/repo && tar -C /work/repo -xf -'
log "Essais dans la VM — journal : ${logf#"$NOMADE_ROOT"/}"
rc=0
"$S/bssh" sudo bash /work/repo/scripts/vm/diag-cle-test-vm.sh >"$logf" 2>&1 || rc=$?
grep -a 'DIAG-CLE-TEST:' "$logf" >&2 || true
((rc == 0)) || die "diag-cle-test : échec (code $rc) — journal : $logf"
log "diag-cle-test : tout est conforme"
