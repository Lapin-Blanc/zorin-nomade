#!/usr/bin/env bash
# Démarre une image dans QEMU sur l'hôte (sans root) et récupère le résultat de l'autotest.
#
#   test-image.sh [--image out/latest.img] [--sb on|off|both] [--timeout 900] [--name sb]
#   test-image.sh --gui [--image …] [--sb on|off]      fenêtre interactive, sans autotest
#   NOMADE_TEST_PASSPHRASE=… test-image.sh --encrypted --image out/deploy-test/stick.img --name deploy
#       clé déployée (scripts/deploy-test.sh) : la phrase LUKS est tapée au clavier virtuel, touches
#       d'un AZERTY belge (si l'initramfs n'était pas en « be », elle serait refusée), quand
#       la question est à l'écran (disque USB inactif depuis 8 s), et l'autotest vérifie aussi le
#       déploiement (fw_cfg opt/nomade/deployed=1).
#
# La clé est simulée en USB (qemu-xhci + usb-storage), la NVRAM UEFI est vierge à chaque
# essai et l'image n'est jamais modifiée (surcouche qcow2 jetable). Résultats dans
# out/test/<nom>-<on|off>/ : serial.log, screen.png, qemu.log ; synthèse dans
# out/test/summary.txt (out/test/summary-<nom>.txt si --name diffère de « sb »).
# Les arguments QEMU contiennent des virgules à dessein :
# shellcheck disable=SC2054
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
host_guard
load_env
require_cmd qemu-system-x86_64 qemu-img python3 timeout

image="$OUT_DIR/latest.img"
sb_mode=both
gui=0
encrypted=0
tname=sb
timeout_s="$TEST_TIMEOUT"
while (($#)); do
  case "$1" in
    --image) image="${2:?}"; shift 2 ;;
    --sb) sb_mode="${2:?}"; shift 2 ;;
    --timeout) timeout_s="${2:?}"; shift 2 ;;
    --gui) gui=1; shift ;;
    --encrypted) encrypted=1; shift ;;
    --name) tname="${2:?}"; shift 2 ;;
    *) die "option inconnue : $1" ;;
  esac
done
[[ -e "$image" ]] || die "image introuvable : $image (make image)"
image="$(readlink -f "$image")"
[[ "$image" != *[,\ ]* ]] || die "le chemin de l'image ne doit contenir ni virgule ni espace : $image"
img_fmt=raw; [[ "$image" == *.qcow2 ]] && img_fmt=qcow2
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm inaccessible (make doctor)"
[[ "$tname" =~ ^[a-z0-9-]+$ ]] || die "--name : lettres minuscules, chiffres et tirets"
if ((encrypted)); then
  [[ -n "${NOMADE_TEST_PASSPHRASE:-}" ]] || die "--encrypted exige NOMADE_TEST_PASSPHRASE"
  [[ "$NOMADE_TEST_PASSPHRASE" =~ ^[a-z]+$ ]] || die "phrase de test : lettres minuscules uniquement"
fi
summary="$OUT_DIR/test/summary.txt"
[[ "$tname" == sb ]] || summary="$OUT_DIR/test/summary-$tname.txt"

# qmp <socket> <commande> [arg] — client QMP minimal :
#   screendump <fichier> · quit · rdops <disque> (lectures cumulées) ·
#   type (tape $NOMADE_TEST_PASSPHRASE puis Entrée, la phrase ne passe jamais en argument ; touches
#   physiques d'un clavier AZERTY belge : « a » = touche qcode q, « z » = w, « m » = point-virgule)
qmp() {
  python3 -I - "$@" <<'PY'
import json, os, socket, sys, time
path, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.settimeout(15)
s.connect(path)
f = s.makefile("rw")
def reply():
    while True:
        line = f.readline()
        if not line:
            return {}
        msg = json.loads(line)
        if "event" not in msg:
            return msg
reply()  # message d'accueil
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); reply()
def call(req):
    f.write(json.dumps(req) + "\n"); f.flush()
    return reply()
if cmd == "type":
    azerty = {"a": "q", "q": "a", "z": "w", "w": "z", "m": "semicolon"}
    for c in [azerty.get(c, c) for c in os.environ["NOMADE_TEST_PASSPHRASE"]] + ["ret"]:
        r = call({"execute": "send-key", "arguments": {"keys": [{"type": "qcode", "data": c}]}})
        if "error" in r:
            sys.exit(r["error"].get("desc", "erreur QMP"))
        time.sleep(0.12)
    sys.exit(0)
if cmd == "rdops":
    r = call({"execute": "query-blockstats"})
    for d in r.get("return", []):
        if d.get("device") == sys.argv[3]:
            print(d["stats"]["rd_operations"])
    sys.exit(0)
req = {"execute": cmd}
if cmd == "screendump":
    req["arguments"] = {"filename": sys.argv[3], "format": "png"}
f.write(json.dumps(req) + "\n"); f.flush()
try:
    r = reply()
except OSError:
    r = {}
if "error" in r:
    sys.exit(r["error"].get("desc", "erreur QMP"))
PY
}

# Construit la ligne de commande QEMU commune dans le tableau global QEMU_CMD.
build_cmd() {
  local sb="$1" dir="$2" code vars machine
  if [[ "$sb" == on ]]; then code="$OVMF_CODE_SB"; vars="$OVMF_VARS_SB"; else code="$OVMF_CODE"; vars="$OVMF_VARS"; fi
  [[ -r "$code" && -r "$vars" ]] || die "firmware OVMF introuvable ($code / $vars)"
  cp "$vars" "$dir/vars.fd"                       # NVRAM vierge : aucune entrée de boot
  qemu-img create -q -f qcow2 -F "$img_fmt" -b "$image" "$dir/stick.qcow2"
  machine="q35,accel=kvm"
  QEMU_CMD=(qemu-system-x86_64 -name "nomade-test-sb-$sb")
  if [[ "$sb" == on ]]; then
    machine+=",smm=on"
    QEMU_CMD+=(-global driver=cfi.pflash01,property=secure,value=on -global ICH9-LPC.disable_s3=1)
  fi
  QEMU_CMD+=(
    -machine "$machine" -cpu host -smp "$TEST_CPUS" -m "$TEST_RAM_MB"
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$code"
    -drive if=pflash,format=raw,unit=1,file="$dir/vars.fd"
    -device qemu-xhci,id=xhci
    -drive if=none,id=stick,format=qcow2,file="$dir/stick.qcow2"
    -device usb-storage,bus=xhci.0,drive=stick,bootindex=0
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
    -device virtio-rng-pci
    -vga virtio
    -serial file:"$dir/serial.log"
    -qmp unix:"$dir/qmp.sock",server=on,wait=off
  )
}

run_gui() {
  local sb="$1"
  local dir="$OUT_DIR/test/gui-sb-$sb"
  rm -rf "$dir"; mkdir -p "$dir"
  build_cmd "$sb" "$dir"
  QEMU_CMD+=(-display gtk,zoom-to-fit=on -device usb-tablet,bus=xhci.0)
  log "Démarrage interactif (Secure Boot $sb) — ferme la fenêtre pour terminer"
  "${QEMU_CMD[@]}"
}

# Déverrouillage LUKS au clavier virtuel (appelée toutes les 3 s par run_selftest, variables
# locales de l'appelant). La question est « visible » quand le disque USB n'est plus lu depuis
# 8 s après le chargement par GRUB (initramfs en attente de la phrase) — le menu GRUB ne dure que
# 3 s. Déverrouillée quand les lectures reprennent en masse (montage de la racine).
unlock_step() {
  rd="$(qmp "$dir/qmp.sock" rdops stick 2>/dev/null || echo 0)"
  [[ "$rd" =~ ^[0-9]+$ ]] || rd=0
  if ((rd == rd_prev && rd > 0)); then still=$((still + 3)); else still=0; fi
  case "$lstate" in
    locked)
      if ((waited >= 15 && still >= 8)); then
        qmp "$dir/qmp.sock" screendump "$dir/question.png" 2>>"$dir/qemu.log" || true
        tries=$((tries + 1))
        log "question LUKS (disque inactif depuis ${still}s, ${waited}s) : saisie de la phrase, essai $tries"
        qmp "$dir/qmp.sock" type 2>>"$dir/qemu.log" || warn "saisie QMP en échec"
        lstate=typed t_typed=$waited rd_typed=$rd still=0
        rd_prev=$rd
        return 0
      fi ;;
    typed)
      if ((rd > rd_typed + 1000)); then
        log "racine déverrouillée $((waited - t_typed))s après la saisie"
        lstate=unlocked
      elif ((waited - t_typed > 60 && still >= 8 && tries < 3)); then
        lstate=locked
      fi ;;
  esac
  rd_prev=$rd
}

# run_selftest <on|off> → 0 si RESULT=PASS
run_selftest() {
  local sb="$1"
  local dir="$OUT_DIR/test/$tname-$sb" pid waited=0 shot=0 after_result=0 result
  local lstate=locked rd=0 rd_prev=-1 rd_typed=0 still=0 tries=0 t_typed=0
  rm -rf "$dir"; mkdir -p "$dir"
  build_cmd "$sb" "$dir"
  QEMU_CMD+=(
    -display none -no-reboot
    -fw_cfg name=opt/nomade/selftest,string=1
    -fw_cfg name=opt/nomade/poweroff,string=1
    -fw_cfg name=opt/nomade/expect_sb,string="$sb"
  )
  if ((encrypted)); then
    QEMU_CMD+=(-fw_cfg name=opt/nomade/deployed,string=1 -fw_cfg name=opt/nomade/expect_usb,string=46f4:0001)
  fi
  log "Essai Secure Boot $sb (délai ${timeout_s}s)…"
  "${QEMU_CMD[@]}" >"$dir/qemu.log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((encrypted)) && [[ "$lstate" != unlocked ]]; then unlock_step; fi
    if grep -aq 'NOMADE-SELFTEST: RESULT=' "$dir/serial.log" 2>/dev/null; then
      if ((!shot)); then qmp "$dir/qmp.sock" screendump "$dir/screen.png" 2>>"$dir/qemu.log" || true; shot=1; fi
      after_result=$((after_result + 3))
      if ((after_result > 90)); then qmp "$dir/qmp.sock" quit 2>/dev/null || kill "$pid" 2>/dev/null || true; fi
    elif ((waited >= timeout_s)); then
      warn "délai dépassé (Secure Boot $sb) — capture d'écran puis arrêt"
      qmp "$dir/qmp.sock" screendump "$dir/screen.png" 2>>"$dir/qemu.log" || true
      qmp "$dir/qmp.sock" quit 2>/dev/null || kill "$pid" 2>/dev/null || true
      break
    fi
    sleep 3; waited=$((waited + 3))
  done
  wait "$pid" 2>/dev/null || true
  rm -f "$dir/stick.qcow2"

  if ((encrypted)) && [[ "$lstate" != unlocked ]]; then
    warn "racine jamais déverrouillée (état : $lstate, $tries saisie(s)) — voir $dir/question.png"
  fi
  result="$(grep -a 'NOMADE-SELFTEST: RESULT=' "$dir/serial.log" 2>/dev/null \
            | tail -n1 | sed 's/.*RESULT=//' | tr -d '\r' || true)"
  {
    printf '== %s Secure Boot %s : %s (%ss)\n' "$tname" "$sb" "${result:-AUCUN RÉSULTAT}" "$waited"
    grep -a 'NOMADE-SELFTEST: FAIL' "$dir/serial.log" 2>/dev/null | sed 's/^.*NOMADE-SELFTEST: /   /' || true
  } | tee -a "$summary" >&2
  [[ "$result" == PASS ]]
}

# D-016 : l'hôte n'a que 7 Gio. Si la mémoire manque pour la VM de test, la VM de build
# (jetable, son disque est conservé) est arrêtée.
mem_available_mb() { awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo; }
ensure_memory() {
  local need=$((TEST_RAM_MB + 512)) avail
  avail="$(mem_available_mb)"
  if ((avail < need)) && [[ -f "$BUILDER_DIR/qemu.pid" ]] \
     && kill -0 "$(cat "$BUILDER_DIR/qemu.pid")" 2>/dev/null; then
    log "mémoire disponible : ${avail} Mio < ${need} Mio → arrêt de la VM de build"
    "$NOMADE_ROOT/scripts/builder.sh" down
    avail="$(mem_available_mb)"
  fi
  if ((avail < need)); then
    warn "seulement ${avail} Mio disponibles pour une VM de ${TEST_RAM_MB} Mio : l'essai risque d'échanger"
  fi
}

mkdir -p "$OUT_DIR/test"
ensure_memory
case "$sb_mode" in
  both) runs=(on off) ;;
  on|off) runs=("$sb_mode") ;;
  *) die "--sb attend on, off ou both" ;;
esac

if ((gui)); then run_gui "${runs[0]}"; exit 0; fi

{ printf 'Image : %s\nDate  : %s\n' "$image" "$(date -Iseconds)"; } >"$summary"
status=0
for sb in "${runs[@]}"; do run_selftest "$sb" || status=1; done
if ((status)); then warn "au moins un essai a échoué — voir ${summary#"$NOMADE_ROOT"/} et out/test/$tname-*/serial.log"
else log "Tous les essais ont réussi"; fi
exit "$status"
