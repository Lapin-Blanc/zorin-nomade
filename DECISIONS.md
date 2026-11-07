# Décisions

Format : `D-nnn — titre` · date · statut (retenue / remplacée par D-xxx) · contexte · décision ·
conséquences. Les décisions D-001 à D-012 ont été prises avec Fabien avant le premier run.

## D-001 — Zorin OS Core 18.x, ni Lite ni Pro
2026-11-07 · retenue
La série 19 sera uniquement GNOME : rester sur Core garde la même recette dans le futur.
Pro n'apporte rien côté réactivité (même base, mêmes réglages possibles).

## D-002 — Système installé plutôt que live persistant
2026-11-07 · retenue
La persistance casper écrit directement sur la clé, fige le noyau de l'ISO et accumule les mises
à jour dans l'overlay. Avec un SSD NVMe sur USB 3, une installation complète est plus rapide
et maintenable. La réactivité « à la MX » est obtenue par des réglages (sysctl dirty_*, zram,
tmpfs, profile-sync-daemon), pas par un root en RAM.

## D-003 — Construction depuis le squashfs, sans installateur
2026-11-07 · retenue
L'installateur Zorin est graphique : il empêcherait toute construction autonome et reproductible.
Le squashfs de l'ISO est décompressé dans l'image puis configuré en chroot.

## D-004 — VM de build jetable, sans root sur l'hôte
2026-11-07 · retenue
Image cloud Ubuntu 24.04 (même base que Zorin 18) + cloud-init, QEMU en mode utilisateur
(pas de libvirt système, dont le groupe équivaut à root). Claude Code tourne sur l'hôte sans
privilèges ; tout ce qui exige root se fait dans la VM via SSH.

## D-005 — Tests de démarrage sur l'hôte, clé simulée en USB
2026-11-07 · retenue
QEMU + KVM + OVMF sur l'hôte (pas de virtualisation imbriquée), `qemu-xhci` + `usb-storage`
pour reproduire le chemin USB du firmware et du noyau, NVRAM vierge à chaque essai,
Secure Boot activé puis désactivé.

## D-006 — Autotest embarqué déclenché par fw_cfg
2026-11-07 · retenue
`nomade-selftest.service` ne s'exécute que dans une VM (`ConditionVirtualization=vm`) et seulement
si QEMU expose `opt/nomade/selftest`. Il est donc inerte sur une vraie machine. Résultats sur le
port série ; capture d'écran par QMP.

## D-007 — Chiffrement LUKS2 au déploiement, pas au build
2026-11-07 · retenue
Une image chiffrée en CI embarquerait une clé de volume connue d'avance. L'image est livrée en
clair ; le déploiement génère la clé de volume sur la clé USB elle-même.

## D-008 — GRUB amovible, sans NVRAM
2026-11-07 · retenue
Seul le chemin `/EFI/BOOT/BOOTX64.EFI` (shim) garantit le démarrage sur n'importe quel PC sans
entrée de boot dédiée ; aucune écriture NVRAM, ni au build ni aux mises à jour.

## D-009 — Pas de démontage à chaud : on privilégie la vitesse
2026-11-07 · retenue
`commit=60`, `dirty_expire` 60 s, dpkg `force-unsafe-io`. Risque résiduel : jusqu'à ~60 s
d'écritures perdues en cas de plantage ou de coupure.

## D-010 — Horloge matérielle en heure locale
2026-11-07 · retenue
La clé tourne souvent sur des PC Windows, qui attendent l'heure locale dans le RTC.

## D-011 — Menu GRUB visible 3 s
2026-11-07 · retenue
Sur un matériel inconnu, pouvoir choisir l'entrée de dépannage vaut les 3 s perdues.

## D-012 — Effort et mode de travail
2026-11-07 · retenue
Phase 0 interactive en effort `xhigh` ; run autonome en effort `high`, mode sans confirmation,
règles `deny` de `.claude/settings.json` comme garde-fous ; projet Debian consulté via une copie
jetable dans `reference/` pour garder les deux projets distincts.
