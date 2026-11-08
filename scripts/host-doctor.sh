#!/usr/bin/env bash
# Vérifie que l'hôte est prêt : outils, KVM, OVMF, espace, port de la VM de build ; signale les
# garde-fous du travail avec Claude Code (root accessible par un détour).
# Code de sortie 1 si un point bloquant est trouvé. Les garde-fous Claude ne sont que des
# avertissements, sauf avec --strict (make doctor STRICT=1) : ils deviennent alors bloquants.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
host_guard
load_env

strict=0
case "${1:-}" in
  --strict) strict=1 ;;
  "") ;;
  *) die "option inconnue : $1 (seule option : --strict)" ;;
esac

blocking=0
warned=0
ok()   { printf '  [ok] %s\n' "$*"; }
ko()   { printf '  [KO] %s\n' "$*"; blocking=1; }
note() { printf '  [!!] %s\n' "$*"; }
# Garde-fou Claude : bloquant en mode strict, avertissement sinon
guard() { if ((strict)); then ko "$*"; else note "$*"; warned=1; fi; }

echo "Outils"
declare -A pkg_of=(
  [qemu-system-x86_64]=qemu-system-x86 [qemu-img]=qemu-utils [cloud-localds]=cloud-image-utils
  [ssh]=openssh-client [ssh-keygen]=openssh-client [curl]=curl [sha256sum]=coreutils
  [make]=make [git]=git [tar]=tar [zstd]=zstd [python3]=python3 [timeout]=coreutils
)
missing_pkgs=()
for c in "${!pkg_of[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else ko "$c manquant"; missing_pkgs+=("${pkg_of[$c]}"); fi
done
for c in shellcheck bmaptool cryptsetup; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"
  else note "$c absent (shellcheck : make lint ; bmaptool/cryptsetup : utiles pour make deploy)"; fi
done
if ((${#missing_pkgs[@]})); then
  mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
  printf '\n  → sudo apt install %s\n\n' "${missing_pkgs[*]}"
fi

echo "Virtualisation"
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ok "/dev/kvm accessible"
else ko "pas d'accès à /dev/kvm → sudo usermod -aG kvm \$USER, puis reconnecte-toi"; fi

echo "Firmware UEFI (paquet ovmf)"
for f in "$OVMF_CODE_SB" "$OVMF_VARS_SB" "$OVMF_CODE" "$OVMF_VARS"; do
  if [[ -r "$f" ]]; then ok "$f"; else ko "$f introuvable (sudo apt install ovmf, ou ajuste config/local.env)"; fi
done

echo "Garde-fous pour Claude Code (ne doit pas pouvoir devenir root) — $( ((strict)) && echo bloquants || echo avertissements, STRICT=1 pour les rendre bloquants)"
if [[ $EUID -eq 0 ]]; then ko "exécuté en root"; fi
if sudo -n true 2>/dev/null; then
  guard "sudo fonctionne sans mot de passe : retire toute règle NOPASSWD (et lance « sudo -k »)"
else
  ok "sudo exige un mot de passe"
fi
groups_list=" $(id -nG) "
risky=0
for g in disk docker lxd incus-admin; do
  if [[ "$groups_list" == *" $g "* ]]; then
    guard "membre du groupe $g (équivaut à root ou à un accès brut aux disques)"; risky=1
  fi
done
if [[ "$groups_list" == *" libvirt "* ]]; then
  note "membre du groupe libvirt (équivaut à root) : le projet ne s'en sert pas, à toi de voir"
fi
((risky)) || ok "aucun groupe équivalent à root détecté"

echo "Espace disque"
avail_gb="$(df -BG --output=avail "$NOMADE_ROOT" | tail -n1 | tr -dc '0-9')"
if ((avail_gb >= MIN_FREE_GB)); then ok "${avail_gb} Gio libres (minimum ${MIN_FREE_GB})"
else ko "${avail_gb} Gio libres, il en faut au moins ${MIN_FREE_GB}"; fi

echo "Port SSH de la VM de build"
if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$BUILDER_SSH_PORT" | grep -q LISTEN; then
  if [[ -f "$BUILDER_DIR/qemu.pid" ]] && kill -0 "$(cat "$BUILDER_DIR/qemu.pid")" 2>/dev/null; then
    ok "port $BUILDER_SSH_PORT utilisé par la VM de build"
  else
    ko "port $BUILDER_SSH_PORT déjà occupé → choisis BUILDER_SSH_PORT dans config/local.env"
  fi
else
  ok "port $BUILDER_SSH_PORT libre"
fi

echo
if ((blocking)); then echo "Des points bloquants sont à corriger."; exit 1; fi
if ((warned)); then
  echo "Hôte prêt. Avertissements [!!] : ils ne concernent que le travail avec Claude Code"
  echo "(docs/developpement/README.md)."
else
  echo "Hôte prêt."
fi
