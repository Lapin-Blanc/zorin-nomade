#!/bin/sh
# zorin-nomade (SPEC E-09, D-029) — maintient le chemin amovible EFI/BOOT, le seul que le firmware
# d'un PC inconnu essaie sans entrée NVRAM.
#
# grub-install (Ubuntu/Zorin) installe dans EFI/ubuntu (préfixe codé en dur dans le GRUB signé) et
# copie dans EFI/BOOT le shim, MokManager et le shim de repli fbx64.efi, mais PAS grubx64.efi :
# shim ne trouverait pas GRUB et lancerait fbx64.efi, qui écrit une entrée NVRAM sur le PC hôte
# puis redémarre. Ce script refait donc de EFI/BOOT une copie de EFI/ubuntu, sans fbx64.efi ni
# BOOTX64.CSV.
#
# Appelé au build et après chaque passage de dpkg (crochet APT 99-nomade-no-shim-fallback).
# N'échoue jamais : il ne doit pas bloquer APT.
EFI=/boot/efi/EFI
SRC="$EFI/ubuntu"
DST="$EFI/BOOT"

[ -d "$SRC" ] || exit 0
mkdir -p "$DST" 2>/dev/null || exit 0

rm -f "$DST/fbx64.efi" "$DST/BOOTX64.CSV"

# sync <source> <destination> : copie atomique si le contenu diffère
sync_file() {
  [ -f "$1" ] || return 0
  cmp -s "$1" "$2" && return 0
  cp "$1" "$2.nomade-tmp" && mv -f "$2.nomade-tmp" "$2"
}
sync_file "$SRC/shimx64.efi" "$DST/BOOTX64.EFI"
sync_file "$SRC/grubx64.efi" "$DST/grubx64.efi"
sync_file "$SRC/mmx64.efi" "$DST/mmx64.efi"
sync_file "$SRC/grub.cfg" "$DST/grub.cfg"
exit 0
