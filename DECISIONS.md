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

## D-013 — ISO Zorin OS 18.1 Core, miroir kernel.org
2026-11-07 · retenue
Dernière version publiée (page de téléchargement officielle : 18.1 ; rien de plus récent sur les
miroirs). Empreinte relevée sur la page d'aide Zorin « Correct SHA256 checksums », identique au
`SHA256SUMS.txt` du miroir. Miroir « World » `mirrors.edge.kernel.org` (le plus rapide des quatre
essayés, ~10 Mo/s). Source et date dans `config/iso.env`.

## D-014 — Reproduire `remove_extras` d'Ubiquity en une seule transaction APT
2026-11-07 · retenue
L'ISO garde le schéma Ubiquity (un seul `filesystem.squashfs` + `filesystem.manifest-remove`).
Ubiquity retire le manifeste moins ce qu'il a installé pendant l'installation (chargeur EFI, langue
choisie) et leurs dépendances. Recette : une transaction `apt-get --purge --auto-remove install`
qui installe `grub-efi-amd64` (absent du squashfs, réseau), zram, psd et retire
`manifest-remove − liste à garder` (29 paquets : chargeur, cryptsetup pour le déploiement,
français, anglais de repli), snapd et census. Simulée en phase 0 : 231 purges, aucune cascade.
Conséquence : la liste à garder est versionnée dans `config/` ; pour Zorin 19, refaire la simulation.

## D-015 — Leçons et conventions reprises du projet Debian
2026-11-07 · retenue
Repris : pas de `fbx64.efi`/`BOOTX64.CSV` dans `EFI/BOOT` (crochet APT), contrôle `cmp` du
`grubx64.efi` amovible (pas la variante CD), `--no-nvram`, NVRAM vierge à chaque essai ; build dans
`unshare --mount --propagation private`, `policy-rc.d`, `--force-confold`, processus du chroot tués
avant démontage ; cache APT hors de l'image ; `e2fsck -f -E discard` au démontage ; `machine-id`
vide ; `KEYMAP=y` et option `initramfs` de crypttab pour le déploiement chiffré ; chiffrer avant
d'agrandir ; phrase de test tapée au clavier virtuel une fois la question visible ; test qui
s'éteint seul ; CI qui construit et teste (D-023).
Non repris : `cipher_null` + chiffrement au premier démarrage (ici le déploiement se fait hors
ligne depuis l'hôte, D-007) ; LVM ; BFQ (la spec demande `mq-deadline` pour un SSD) ; initramfs
allégé (clé rapide, à reconsidérer si le démarrage s'avère lent) ; navigateur et réglages KDE.

## D-016 — Mémoire des VM ramenée à 3 Gio
2026-11-07 · retenue
L'hôte de Fabien a 7 Gio de RAM (≈ 2 Gio disponibles avec VS Code et Brave ouverts) :
`BUILDER_RAM_MB=6144` et `TEST_RAM_MB=4096` le feraient échanger lourdement. 3 Gio suffisent au
build (unsquashfs, apt en chroot) et à une session GNOME de test. Conséquence : la VM de build ne
doit pas tourner pendant `make test` si la mémoire manque (à gérer dans le harnais, phase 1).

## D-017 — Scripts de build exécutables dans la VM ou sur un runner CI
2026-11-07 · retenue
Les scripts root (`scripts/vm/…`) prennent leurs chemins en arguments et ne supposent ni SSH ni la
VM : ils tournent tels quels dans la VM de build (via `bssh sudo`) ou sur un runner GitHub
(`sudo`). `scripts/build-image.sh` (hôte) ne fait qu'orchestrer : envoi du dépôt et de l'ISO,
exécution, rapatriement. Nécessaire pour D-023.

## D-018 — Identité des commits
2026-11-07 · retenue (Fabien)
Configuration git locale du dépôt : « Fabien Toune <2578326+Lapin-Blanc@users.noreply.github.com> »,
comme le projet Debian (pas d'adresse personnelle exposée si le dépôt devient public).

## D-019 — Garde-fous de l'hôte : situation acceptée par Fabien
2026-11-07 · retenue (Fabien)
Le compte de Fabien reste dans `docker` et `libvirt` (`make doctor` reste [KO] sur ce point) et
`.claude/settings.json` ne contient que `allow: Bash(*)` (règles `deny` inactives, conservées dans
`.claude/settings copy.json`). Les deux fichiers sont versionnés tels quels. Claude n'utilise
jamais docker, podman ni libvirt et applique les règles de `CLAUDE.md` comme si les `deny`
étaient actives.

## D-020 — E-26 : noms indexés, contenu non
2026-11-07 · retenue
Zorin 18.1 a Tracker 3.7. L'overlay d'origine vidait les dossiers indexés et désactivait
l'exploration : plus aucune recherche par nom dans la vue d'ensemble, contraire à E-26. Correction :
réglages par défaut de `miner/files` (noms et métadonnées des dossiers XDG), `extract max-bytes=0`
et `text-allowlist=[]` (pas de texte intégral). Vérifié par `gsettings` dans le chroot.

## D-021 — E-25 : psd avec une définition Brave
2026-11-07 · retenue (Fabien)
Zorin 18.1 Core livre Brave et pas Firefox ; psd 6.50 n'a pas de définition Brave. Ajout de
`/usr/share/psd/browsers/brave` (`DIRArr[0]="$XDG_CONFIG_HOME/BraveSoftware/Brave-Browser"`,
`PSNAME="brave"`) par l'overlay ; Brave reste le navigateur par défaut ; SPEC E-25 reformulée.

## D-022 — Mises à jour de sécurité automatiques conservées
2026-11-07 · retenue (Fabien)
`unattended-upgrades` et les minuteries `apt-daily*` de Zorin restent actifs ; seul GNOME Logiciels
ne télécharge plus en arrière-plan (E-26). Les mises à jour de GRUB et de shim passent par les
réglages debconf de E-09 et le crochet anti-`fbx64.efi`.

## D-023 — CI complète sur GitHub Actions
2026-11-07 · retenue (Fabien)
Comme le projet Debian : lint à chaque push ; construction + `make test` (Secure Boot on/off) sur
un runner ubuntu-24.04 (root, KVM par règle udev) quand les scripts ou la configuration changent,
et à la demande. ISO en cache (`actions/cache`, clé = SHA-256). Pas d'image en artefact (plusieurs
Gio) : journaux, `serial.log`, captures. Suppose un dépôt GitHub créé par Fabien (A-FAIRE-FABIEN).

## D-024 — Services désactivés sur la clé
2026-11-07 · retenue (Fabien)
`smartd`/`smartmontools` (inutile à travers un pont USB, sonde les disques de l'hôte),
`NetworkManager-wait-online` (attente au démarrage), `whoopsie` et `kerneloops` (rapports envoyés
à Canonical), `ModemManager`. Désactivés (`systemctl disable`, `.path` compris), pas désinstallés.
Nouvelle exigence E-40.

## D-025 — zorin-os-census retiré
2026-11-07 · retenue (Fabien)
Équivaut à décocher la case de l'installateur ; ajouté à la transaction de D-014. Exigence E-39.

## D-026 — os-prober désactivé
2026-11-07 · retenue
Le `30_os-prober` d'Ubuntu s'exécute quand `GRUB_DISABLE_OS_PROBER` n'est pas défini : au build il
ajouterait l'Ubuntu de la VM, sur la clé il sonderait le PC hôte à chaque `update-grub`.
`GRUB_DISABLE_OS_PROBER=true` dans `grub.d/60-nomade.cfg`. Exigence E-41.

## D-027 — snapd retiré
2026-11-07 · retenue
Vérifié en phase 0 : snapd 2.73 installé mais aucun snap (ni seed ni snap installé). Retrait de
`snapd` et `gnome-software-plugin-snap` (E-27).

## D-028 — mokutil et cryptsetup gardés dans l'image
2026-11-07 · retenue
Le manifeste les retire. `mokutil` (gardé par Ubiquity en EFI) sert au diagnostic
(`mokutil --sb-state`) sur un PC inconnu ; `cryptsetup`, `cryptsetup-initramfs`, `keyutils` sont
nécessaires à la racine LUKS du déploiement (E-30), sans réseau au moment du déploiement.

## D-029 — GRUB : installation Ubuntu dans `EFI/ubuntu`, puis `EFI/BOOT` resynchronisé
2026-11-07 · retenue (révisée le 2026-11-08)
Constaté en phase 1 (essais de `grub-install` en chroot jetable, puis sur l'image) : le
`grub-install` de Zorin 18.1 n'a pas l'option `--force-extra-removable` (option Debian). Avec
`/etc/default/grub` présent (voir D-032), il installe dans `EFI/ubuntu` — dossier imposé de toute
façon par le préfixe `/EFI/ubuntu` codé en dur dans le `grubx64.efi` signé — et copie dans
`EFI/BOOT` le shim, `mmx64.efi` et `fbx64.efi`, **mais pas `grubx64.efi`** : shim lancerait alors
`fbx64.efi` (entrée NVRAM puis redémarrage). Avec `--removable`, c'est la variante CD `gcdx64`
qui va dans `EFI/BOOT` (invite `grub>`).
Décision : `grub-install --target=x86_64-efi --efi-directory=/boot/efi --uefi-secure-boot
--no-nvram`, puis `/usr/local/lib/nomade/efi-removable-sync.sh`, qui refait de `EFI/BOOT` une copie
du dossier fournisseur le plus récent (shim → `BOOTX64.EFI`, `grubx64.efi`, `mmx64.efi`, `grub.cfg`),
sans `fbx64.efi` ni `BOOTX64.CSV`, et dépose le `grub.cfg` de renvoi dans `EFI/ubuntu` quel que soit le
dossier choisi. Le crochet APT `99-nomade-no-shim-fallback` appelle ce script après chaque passage de
dpkg. Vérifié par une mise à jour simulée de `shim-signed` et `grub-efi-amd64-signed` (réinstallation
par APT) : `EFI/BOOT` reste identique à `EFI/ubuntu`, le `fbx64.efi` remis par `grub-install` est
retiré. Cette mise à jour simulée fait désormais partie du build (D-033).

## D-030 — Liste des paquets du manifeste gardés : 26 paquets explicites
2026-11-07 · retenue
`docs/iso-notes.md` annonçait 29 paquets gardés mais n'en nommait que 26 (chargeur, chiffrement,
français, anglais de repli). La liste versionnée (`config/packages/keep.list`) reprend ces 26 noms :
les variantes anglaises de LibreOffice (`l10n-en-gb`, `l10n-en-za`, `help-en-gb`) n'ont pas
d'utilité pour une clé en `fr_BE`. À revoir si `check-language-support -l fr` (phase 2) propose
un paquet retiré.

## D-031 — Deux images gardées dans `out/`
2026-11-07 · retenue
Chaque image occupe ~10 Gio sur l'hôte ; `scripts/build-image.sh` ne garde que les
`KEEP_IMAGES=2` plus récentes (paramètre de `config/project.env`). Elles sont reconstructibles.

## D-032 — `/etc/default/grub` de Zorin restauré après la transaction APT
2026-11-08 · retenue
`/etc/default/grub` est géré par ucf pour `grub-pc` : dans la transaction de D-014, `grub-efi-amd64`
le reprend, puis la purge de `grub-pc` le supprime. Sans lui, GRUB perd les réglages Zorin (`quiet
splash`, thème, `GRUB_DISTRIBUTOR`) : menu « GNU/Linux » et dossier `EFI/grub`. Le build en garde une
copie avant la transaction et la remet s'il a disparu ; contrôle bloquant : première entrée du menu
« Zorin ».

## D-033 — `grub-install` dévié : jamais d'écriture NVRAM, même aux mises à jour
2026-11-08 · retenue
Constaté par la mise à jour simulée de D-029 : `grub-multi-install` (appelé par les scripts de
`shim-signed` et `grub-efi-amd64-signed`) lance `grub-install` sans `--no-nvram` et ignore
`grub2/update_nvram=false` ; sur la clé, une mise à jour créerait une entrée de démarrage dans le
firmware du PC hôte (contraire à D-008/E-09). `/usr/sbin/grub-install` est dévié
(`dpkg-divert --local --rename` → `grub-install.real`) et remplacé par un lien vers
`/usr/local/lib/nomade/grub-install-no-nvram`, qui ajoute toujours `--no-nvram`. La déviation survit
aux mises à jour de `grub2-common`. Le build réinstalle shim et GRUB par APT et échoue si la sortie
trahit une tentative d'écriture NVRAM ou si l'enveloppe a été remplacée.

## D-034 — Disposition clavier de l'initramfs : vérifiée dès l'image
2026-11-08 · retenue
Constaté au build : sous Zorin/Ubuntu, `KEYMAP=y` n'a pas d'effet (le crochet `keymap` de Debian
n'existe pas) ; le crochet `console_setup` embarque **toujours** `/etc/default/keyboard` et la
disposition préparée par `setupcon --save-only` (`etc/console-setup/cached_UTF-8_del.kmap.gz`),
chargée par `init-top/console_setup` avant la question LUKS. Le build (et le déploiement) échouent
si un initrd n'embarque pas ces fichiers ; l'autotest le vérifie (E-12). `KEYMAP=y` est quand même
posé par l'overlay (`conf.d/60-nomade-keymap`), sans effet aujourd'hui, au cas où une version future
reprendrait le crochet Debian. La saisie au clavier belge est **prouvée** par `make deploy-test` : la phrase
contient « a », « z » et « m » et le harnais tape les touches physiques d'un AZERTY (qcode `q` pour
« a », `w` pour « z », `semicolon` pour « m ») ; elle n'est acceptée que si l'initramfs est en `be`
(écart à D-015, où la phrase évitait ces lettres).

## D-035 — Racine chiffrée par recréation, pas par chiffrement en place
2026-11-08 · retenue
Le plan prévoyait `cryptsetup reencrypt --encrypt` en place (repli : recréation). Le chiffrement en
place traite **toute** la partition, blocs libres compris : sur une clé de 1 To, ≈ 1 To lu et écrit ;
pour `make deploy-test`, le fichier creux de 64 Gio deviendrait plein (≈ 60 Gio à rapatrier sur un
hôte de 111 Gio). Retenu : après `bmaptool` et l'agrandissement de p3, `blkdiscard` de p3 (le clair
copié est rendu au SSD), `luksFormat` LUKS2 (secteurs de 4 Kio, clé de volume tirée par cryptsetup sur
la machine qui déploie), `mkfs.ext4` avec **le même UUID et la même étiquette** que la racine de
l'image et le `mke2fs.conf` de la cible, puis `rsync -aHAXS --numeric-ids` depuis la racine de l'image
montée en lecture seule. Seules les données utiles (≈ 6,5 Gio) sont écrites ; `fstab` (UUID, E-07) et
`grub.cfg` (`root=UUID=…`) restent valides sans réécriture ; plus besoin de réduire puis d'agrandir.
Conséquences : l'image doit rester accessible pendant le déploiement (c'est le cas : `out/latest.img`) ;
la mise en garde « chiffrer avant d'agrandir » (D-015) ne s'applique plus.

## D-036 — Déploiement : détails pratiques
2026-11-08 · retenue
- Essai de TRIM sur le premier Mio de la clé (effacé juste après) ; s'il réussit, toute la clé est
  `blkdiscard`ée avant l'écriture (repart de zéro, E-34) et la règle udev reçoit
  `provisioning_mode=unmap` ; sinon `wipefs -a` et règle sans cette ligne.
- Pendant un déploiement réel, une règle udev **temporaire** dans `/run/udev/rules.d/` pose
  `UDISKS_IGNORE=1` sur la clé (GNOME ne monte pas ses partitions au fil de l'écriture) ; retirée en fin
  de script, même en cas d'échec. Rien n'est écrit dans `/etc` de l'hôte.
- Phrase et mot de passe saisis deux fois, sans écho, ASCII uniquement (la console de l'initramfs ne
  reproduit pas sûrement les caractères accentués) ; transmis à `cryptsetup`/`chpasswd` par des tubes.
- Mappeur `nomade-root` (nom de `crypttab`) ; si ce nom est déjà pris (déploiement lancé depuis une clé
  nomade), `nomade-root-deploy` le temps du déploiement.
- Mode test uniquement : PBKDF argon2id allégé (64 Mio, 4 itérations) pour un déverrouillage rapide
  dans QEMU ; le déploiement réel garde les paramètres mesurés par cryptsetup.

## D-037 — Test chiffré : question détectée par l'inactivité du disque
2026-11-08 · retenue
Pas d'OCR et pas de console série avant l'autotest (`quiet splash`, rien à ajouter à la ligne de
commande du système déployé) : le harnais lit par QMP les lectures cumulées du disque USB
(`query-blockstats`). Après le chargement par GRUB, l'initramfs attend la phrase sans plus rien lire :
« question visible » = au moins 15 s écoulées et aucune lecture depuis 8 s (le menu GRUB ne dure que
3 s). La phrase est alors tapée par `send-key` (touches d'un AZERTY belge, D-034), une
capture `question.png` est prise ; la reprise massive des lectures signe le déverrouillage ; trois
essais au plus. La phrase passe par l'environnement, jamais en argument de commande.

## D-038 — `/tmp` : copie de `tmp.mount` dans `/etc`
2026-11-08 · retenue
Méthode documentée par Ubuntu : `/usr/share/systemd/tmp.mount` copié dans `/etc/systemd/system/`
puis activé (le build échoue si le fichier existait déjà). Une mise à jour de systemd ne modifiera pas
la copie ; l'unité est stable depuis des années (`size=50%`, `nr_inodes=1m`).
