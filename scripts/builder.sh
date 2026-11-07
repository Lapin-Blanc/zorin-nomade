#!/usr/bin/env bash
# VM de build jetable : image cloud Ubuntu 24.04 + cloud-init, QEMU en mode utilisateur.
# Aucun privilège requis sur l'hôte ; root est disponible DANS la VM (sudo sans mot de passe).
#
#   builder.sh up                     crée (si besoin) et démarre la VM, attend cloud-init
#   builder.sh down                   arrête la VM (disque conservé)
#   builder.sh destroy                arrête et supprime la VM (l'image de base reste en cache)
#   builder.sh status                 état de la VM
#   builder.sh push <src-hôte> <dossier-vm>   copie (tar sur SSH, fichiers creux préservés)
#   builder.sh pull <src-vm> <dossier-hôte>   idem dans l'autre sens
#   builder.sh console                dernières lignes de la console série de la VM
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
host_guard
load_env

DISK="$BUILDER_DIR/disk.qcow2"
SEED="$BUILDER_DIR/seed.img"
PIDFILE="$BUILDER_DIR/qemu.pid"
SSHCFG="$BUILDER_DIR/ssh_config"
KEY="$BUILDER_DIR/id_ed25519"
CONSOLE_LOG="$BUILDER_DIR/console.log"
BASE_LINK="$BUILDER_DIR/base.img"     # lien vers l'image de base utilisée par ce disque

bssh() { ssh -F "$SSHCFG" builder "$@"; }

is_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

# Télécharge et vérifie l'image cloud. Le nom du fichier en cache contient le début de
# son empreinte : une nouvelle image « current » ne remplace jamais celle d'un disque existant.
fetch_base() {
  local name sums expected cached
  name="$(basename "$BUILDER_IMAGE_URL")"
  sums="$CACHE_DIR/builder-SHA256SUMS"
  mkdir -p "$CACHE_DIR"
  curl -fsSL --retry 3 -o "$sums" "$BUILDER_SHA256SUMS_URL" \
    || die "impossible de récupérer $BUILDER_SHA256SUMS_URL"
  expected="$(awk -v n="$name" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1 }' "$sums")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "empreinte introuvable pour $name dans SHA256SUMS"
  cached="$CACHE_DIR/builder-${expected:0:12}-$name"
  if [[ ! -f "$cached" ]]; then
    log "Téléchargement de l'image cloud $name…"
    curl -fL --retry 3 -o "$cached.part" "$BUILDER_IMAGE_URL"
    mv "$cached.part" "$cached"
  fi
  echo "$expected  $cached" | sha256sum -c --quiet - \
    || { rm -f "$cached"; die "empreinte invalide pour $name (fichier supprimé, relance)"; }
  log "Image cloud vérifiée : $(basename "$cached")"
  printf '%s\n' "$cached"
}

write_ssh_config() {
  cat >"$SSHCFG" <<EOF
Host builder
  HostName 127.0.0.1
  Port $BUILDER_SSH_PORT
  User builder
  IdentityFile "$KEY"
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ConnectTimeout 5
  ServerAliveInterval 30
  ServerAliveCountMax 6
EOF
}

create() {
  local base pub
  require_cmd qemu-img cloud-localds ssh-keygen curl sha256sum
  mkdir -p "$BUILDER_DIR"
  base="$(fetch_base)"
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C nomade-builder -f "$KEY"
  pub="$(cat "$KEY.pub")"
  sed "s|@SSH_PUBKEY@|$pub|" "$NOMADE_ROOT/builder/user-data.in" >"$BUILDER_DIR/user-data"
  sed "s|@INSTANCE_ID@|nomade-builder-$(date +%s)|" "$NOMADE_ROOT/builder/meta-data.in" \
    >"$BUILDER_DIR/meta-data"
  cloud-localds "$SEED" "$BUILDER_DIR/user-data" "$BUILDER_DIR/meta-data"
  ln -sfn "$base" "$BASE_LINK"
  qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$DISK" "${BUILDER_DISK_GB}G"
  write_ssh_config
  log "VM de build créée (disque ${BUILDER_DISK_GB} Gio, creux)"
}

start() {
  require_cmd qemu-system-x86_64 ssh
  [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm inaccessible (voir make doctor)"
  : >"$CONSOLE_LOG"
  qemu-system-x86_64 \
    -name nomade-builder \
    -machine q35,accel=kvm -cpu host \
    -smp "$BUILDER_CPUS" -m "$BUILDER_RAM_MB" \
    -drive file="$DISK",if=virtio,format=qcow2,discard=unmap,cache=unsafe \
    -drive file="$SEED",if=virtio,format=raw,readonly=on \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$BUILDER_SSH_PORT"-:22 \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    -display none -serial file:"$CONSOLE_LOG" \
    -daemonize -pidfile "$PIDFILE"
  log "VM de build démarrée (pid $(cat "$PIDFILE")), attente de SSH…"
}

wait_ready() {
  local waited=0 status
  until bssh true 2>/dev/null; do
    is_running || die "QEMU s'est arrêté — voir $CONSOLE_LOG"
    ((waited < BUILDER_BOOT_TIMEOUT)) || die "SSH injoignable après ${BUILDER_BOOT_TIMEOUT}s — voir $CONSOLE_LOG"
    sleep 5; waited=$((waited + 5))
  done
  log "SSH disponible, attente de la fin de cloud-init…"
  bssh 'cloud-init status --wait >/dev/null 2>&1; cloud-init status' | tee "$BUILDER_DIR/cloud-init.status" >&2 || true
  status="$(tail -n1 "$BUILDER_DIR/cloud-init.status" 2>/dev/null || true)"
  [[ "$status" == *done* ]] || warn "cloud-init ne s'est pas terminé proprement ($status) — vérifie ./scripts/bssh sudo cloud-init status --long"
  bssh 'test -f /var/lib/nomade-builder-ready' || die "la VM n'a pas fini sa préparation (paquets cloud-init)"
  if bssh 'test -s /var/lib/nomade-builder-missing' 2>/dev/null; then
    warn "outils absents dans la VM : $(bssh 'tr "\n" " " < /var/lib/nomade-builder-missing')"
    warn "→ ./scripts/bssh sudo apt-get install … (et corrige builder/user-data.in)"
  fi
  log "VM de build prête : ./scripts/bssh <commande>"
}

cmd_up() {
  if is_running; then
    log "VM de build déjà en marche"
  else
    [[ -f "$DISK" && -f "$SEED" && -f "$SSHCFG" ]] || create
    start
  fi
  wait_ready
}

cmd_down() {
  local waited=0
  if ! is_running; then log "VM de build déjà arrêtée"; return 0; fi
  bssh 'sudo systemctl poweroff' 2>/dev/null || true
  while is_running && ((waited < 90)); do sleep 3; waited=$((waited + 3)); done
  if is_running; then warn "arrêt forcé"; kill "$(cat "$PIDFILE")" || true; sleep 2; fi
  rm -f "$PIDFILE"
  log "VM de build arrêtée"
}

cmd_destroy() {
  cmd_down
  rm -f "$DISK" "$SEED" "$SSHCFG" "$KEY" "$KEY.pub" "$BASE_LINK" "$CONSOLE_LOG" \
        "$BUILDER_DIR/user-data" "$BUILDER_DIR/meta-data" "$BUILDER_DIR/cloud-init.status"
  log "VM de build supprimée (image de base conservée dans cache/)"
}

cmd_status() {
  if is_running; then
    echo "en marche (pid $(cat "$PIDFILE"))"
    if bssh true 2>/dev/null; then echo "SSH : ok"; bssh 'df -h / | tail -n1'; else echo "SSH : injoignable"; fi
  elif [[ -f "$DISK" ]]; then
    echo "arrêtée (disque présent)"
  else
    echo "inexistante"
  fi
}

# push <src-hôte> <dossier-vm> : copie un fichier ou dossier, en préservant les fichiers creux.
cmd_push() {
  local src="${1:?source hôte}" dest="${2:?dossier dans la VM}"
  [[ -e "$src" ]] || die "introuvable : $src"
  tar -C "$(dirname "$src")" -cSf - "$(basename "$src")" \
    | bssh "mkdir -p '$dest' && tar -C '$dest' -xSf -"
}

# pull <src-vm> <dossier-hôte>
cmd_pull() {
  local src="${1:?source dans la VM}" dest="${2:?dossier hôte}"
  mkdir -p "$dest"
  bssh "tar -C \"\$(dirname '$src')\" -cSf - \"\$(basename '$src')\"" | tar -C "$dest" -xSf -
}

cmd_console() { tail -n "${1:-60}" "$CONSOLE_LOG"; }

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  status) cmd_status ;;
  push) shift; cmd_push "$@" ;;
  pull) shift; cmd_pull "$@" ;;
  console) shift; cmd_console "$@" ;;
  *) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
