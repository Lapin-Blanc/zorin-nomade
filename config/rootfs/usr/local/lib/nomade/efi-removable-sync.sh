#!/bin/bash
# zorin-nomade (SPEC E-09, D-029) — maintient le chemin amovible EFI/BOOT, le seul que le firmware
# d'un PC inconnu essaie sans entrée NVRAM.
#
# grub-install (Zorin/Ubuntu) installe shim + GRUB signé dans un dossier « fournisseur »
# (EFI/<distribution>, par ex. « EFI/Zorin OS ») et copie dans EFI/BOOT le shim, MokManager et
# le shim de repli fbx64.efi, mais PAS grubx64.efi : shim ne trouverait pas GRUB et lancerait
# fbx64.efi, qui écrit une entrée NVRAM sur le PC hôte puis redémarre. Ce script refait donc de
# EFI/BOOT une copie du dossier fournisseur le plus récent, sans fbx64.efi ni BOOTX64.CSV, et
# dépose le grub.cfg de renvoi (vers /boot) partout où le GRUB signé peut le chercher :
# dossier de lancement, EFI/BOOT et EFI/ubuntu (préfixe codé en dur dans le GRUB signé d'Ubuntu).
#
# Appelé au build et après chaque passage de dpkg (crochet APT 99-nomade-no-shim-fallback).
# N'échoue jamais : il ne doit pas bloquer APT.
EFI=/boot/efi/EFI
DST="$EFI/BOOT"
[ -d "$EFI" ] || exit 0

# Dossier fournisseur : celui dont le grubx64.efi (accompagné d'un shim) est le plus récent.
SRC=""
for d in "$EFI"/*/; do
  d="${d%/}"
  [[ "$d" != "$DST" && -f "$d/shimx64.efi" && -f "$d/grubx64.efi" ]] || continue
  if [[ -z "$SRC" || "$d/grubx64.efi" -nt "$SRC/grubx64.efi" ]]; then SRC="$d"; fi
done
[ -n "$SRC" ] || exit 0
mkdir -p "$DST" 2>/dev/null || exit 0

rm -f "$DST/fbx64.efi" "$DST/BOOTX64.CSV"

# sync_file <source> <destination> : copie atomique si le contenu diffère
sync_file() {
  [ -f "$1" ] || return 0
  cmp -s "$1" "$2" && return 0
  cp "$1" "$2.nomade-tmp" && mv -f "$2.nomade-tmp" "$2"
}
sync_file "$SRC/shimx64.efi" "$DST/BOOTX64.EFI"
sync_file "$SRC/grubx64.efi" "$DST/grubx64.efi"
sync_file "$SRC/mmx64.efi" "$DST/mmx64.efi"
if [ -f "$SRC/grub.cfg" ]; then
  sync_file "$SRC/grub.cfg" "$DST/grub.cfg"
  mkdir -p "$EFI/ubuntu" 2>/dev/null && sync_file "$SRC/grub.cfg" "$EFI/ubuntu/grub.cfg"
fi
exit 0
