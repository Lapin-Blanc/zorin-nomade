#!/usr/bin/env bash
# Télécharge l'ISO Zorin décrite dans config/iso.env dans cache/ et vérifie son SHA-256.
# Affiche le chemin de l'ISO sur la sortie standard.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
host_guard
load_env
require_cmd curl sha256sum

[[ -n "${ISO_URL:-}" ]] || die "ISO_URL vide dans config/iso.env (à remplir en phase 0)"
[[ "${ISO_SHA256:-}" =~ ^[0-9a-fA-F]{64}$ ]] || die "ISO_SHA256 absent ou invalide dans config/iso.env"

mkdir -p "$CACHE_DIR"
iso="$CACHE_DIR/$(basename "${ISO_URL%%\?*}")"
check() { echo "${ISO_SHA256,,}  $iso" | sha256sum -c --quiet - 2>/dev/null; }

if [[ -f "$iso" ]] && check; then
  log "ISO déjà présente et vérifiée : $(basename "$iso")"
else
  log "Téléchargement de $(basename "$iso")…"
  curl -fL --retry 3 -C - -o "$iso.part" "$ISO_URL"
  mv "$iso.part" "$iso"
  check || { mv "$iso" "$iso.invalide"; die "SHA-256 incorrect — fichier renommé en $(basename "$iso").invalide"; }
  log "ISO vérifiée : $(basename "$iso")"
fi
ln -sfn "$(basename "$iso")" "$CACHE_DIR/zorin.iso"
printf '%s\n' "$iso"
