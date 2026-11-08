# zorin-nomade

Construction reproductible d'un **Zorin OS 18 Core installé** sur clé USB (SSD NVMe
derrière un pont USB), démarrable sur n'importe quel PC UEFI, Secure Boot compris.
Le travail est fait par Claude Code ; ce fichier s'adresse à toi.

- `SPEC.md` : le système visé. `PLAN.md` : les phases. `DECISIONS.md` : les choix.
- `CLAUDE.md` : les consignes de travail de Claude Code (lues automatiquement).

## 1. Préparer l'hôte (une seule fois, avec sudo)

```bash
sudo apt install qemu-system-x86 qemu-system-gui qemu-utils ovmf cloud-image-utils \
                 openssh-client curl make git zstd shellcheck python3 \
                 bmap-tools cryptsetup exfatprogs gdisk rsync dosfstools
# accès à /dev/kvm sans root (si « make doctor » le signale), puis reconnecte-toi :
sudo usermod -aG kvm "$USER"
```

Garde-fous attendus par `make doctor` :
- pas de `sudo` sans mot de passe (aucune règle `NOPASSWD` pour ton compte) ;
- ton compte n'est ni dans `disk`, ni dans `docker`/`lxd`/`incus-admin` (équivalents root).
  `libvirt` est signalé comme avertissement : le projet ne s'en sert pas.
- environ **80 Gio** libres dans le dossier du projet.

## 2. Mettre en place le dépôt

```bash
tar xzf zorin-nomade-base.tar.gz && cd zorin-nomade
git init && git add -A && git commit -m "Base du projet"
# copie jetable du projet Debian, en lecture seule pour Claude (non versionnée) :
git clone --depth 1 /chemin/vers/ton-projet-debian reference/debian
make doctor
```

## 3. Phase 0 — interactive

```bash
claude --model opus --effort xhigh
```
Colle le contenu de `prompts/phase0.md`. Claude inspecte l'ISO, ajuste le plan, puis s'arrête
sur une synthèse. Valide-la ou corrige-la avant le run.

## 4. Run autonome

```bash
claude --model opus --effort high --dangerously-skip-permissions
```
Colle le contenu de `prompts/run.md`. La première fois, Claude Code affiche un avertissement
sur le mode sans confirmation : accepte-le. Les règles `deny` de `.claude/settings.json`
s'appliquent dans ce mode si elles y figurent (ce n'est pas le cas aujourd'hui, D-019 : seules
les consignes de `CLAUDE.md` protègent alors l'hôte), et Claude n'a de toute façon pas root sur
l'hôte.

Si la limite d'usage coupe le run :
```bash
claude --continue --dangerously-skip-permissions
```
puis « Relis PLAN.md, DECISIONS.md et docs/JOURNAL.md, et continue le plan. »

## 5. Après le run : déployer sur la clé

```bash
make test-gui                     # démarre la dernière image dans une fenêtre, pour regarder
ls -l /dev/disk/by-id/ | grep usb # repère ta clé SSK (le disque entier, sans « -part »)
sudo make deploy KEY=/dev/disk/by-id/usb-…
```
Le déploiement (`scripts/deploy.sh`, ≈ 10 min sur une clé USB 3) :
1. affiche modèle, numéro de série et taille de la clé et te demande de **taper le numéro de
   série** avant d'écrire quoi que ce soit ;
2. te demande la **phrase de passe LUKS** (deux fois, ASCII uniquement : elle se tapera en clavier
   belge au démarrage) puis le **mot de passe** de ton compte ;
3. essaie le TRIM à travers le pont USB, efface la clé, écrit l'image (`bmaptool`), agrandit la
   racine jusqu'au bout de la clé (moins `DEPLOY_DATA_GIB` si tu veux une partition exFAT
   `NOMADE-DATA` lisible sous Windows), la chiffre en LUKS2 (clé de volume tirée sur place),
   règle l'initramfs, GRUB et la règle udev du pont, contrôle tout, puis affiche la checklist du
   premier démarrage (détaillée dans `docs/RAPPORT.md`).

Paramètres (`config/project.env`, surcharges dans `config/local.env`) : `DEPLOY_ENCRYPT=1`,
`DEPLOY_DATA_GIB=0`. Outils nécessaires sur l'hôte : ceux de la section 1 (`bmap-tools`,
`cryptsetup`, `gdisk`, `rsync`, `exfatprogs` si partition de données) — tous présents chez toi.
Relancer le déploiement sur la même clé repart de zéro.

**Secure Boot et PC « Secured-core »** : le shim est signé par « Microsoft Corporation UEFI CA 2011 ».
Certains PC récents ne font pas confiance à cette autorité tant qu'une option du firmware n'est pas
activée (par exemple HP : « Enable MS UEFI CA key » dans la configuration Secure Boot ; Lenovo : « Allow Microsoft
3rd Party UEFI CA »). C'est le cas du HP ProBook 455 G10 (db sans cette autorité, constaté le
2026-11-08) : avec Secure Boot activé, il refuse la clé tant que l'option est coupée. Sinon, désactiver
Secure Boot. Les certificats Microsoft de 2011 expirent en 2026 : surveiller les mises à jour de
`shim-signed` (futurs shims signés par l'autorité de 2023).

`make deploy-test` rejoue tout cela sans toi : dans la VM de build, vers un fichier creux de
64 Gio, avec une phrase et un mot de passe générés pour l'occasion, puis démarre le fichier
dans QEMU sur l'hôte et tape la phrase au clavier virtuel.

## 5 bis. Intégration continue (GitHub Actions)

- `lint.yml`, à chaque push : `make ci` (shellcheck + refus attendus des garde-fous).
- `image.yml`, quand `scripts/`, `config/`, le `Makefile` ou le workflow changent, et à la
  demande (onglet *Actions* → *image* → *Run workflow*) : construction de l'image directement
  sur le runner (root, sans VM de build), puis `make test` (Secure Boot activé et désactivé).
  ISO en cache (clé = SHA-256). En artefact : journaux, sortie série, captures, manifeste —
  **pas l'image**.
- Ne tournent qu'en local : `make deploy` (ta clé), `make deploy-test` (déploiement chiffré
  complet, ≈ 15 min, trop de transferts pour un runner), `make test-gui`.
Mise en route : voir `docs/A-FAIRE-FABIEN.md`.

## 6. Ajustements ultérieurs depuis VS Code

Oui : ouvre le dossier dans VS Code et utilise l'extension Claude Code. Elle lit le même
`CLAUDE.md` et les mêmes règles `deny` ; `PLAN.md`, `DECISIONS.md` et `docs/JOURNAL.md`
lui donnent tout l'historique. Deux différences avec le terminal :
- l'extension ne lit pas `.claude/settings.json` pour le **mode de départ** ; par défaut elle
  démarre en mode auto, ce qui convient bien aux retouches ;
- le mode « Bypass permissions » n'y apparaît qu'après avoir activé
  **Allow dangerously skip permissions** dans les réglages de l'extension.

Pour une retouche, décris le changement voulu et demande que `SPEC.md` (si l'exigence change),
`DECISIONS.md` et l'autotest soient mis à jour, puis `make all`.

## Structure

```
CLAUDE.md SPEC.md PLAN.md DECISIONS.md   consignes, cible, plan, décisions
Makefile                                 point d'entrée (make help)
config/project.env, config/iso.env       paramètres (iso.env rempli en phase 0)
config/rootfs/                           overlay copié dans le système cible
config/templates/                        modèles remplis au déploiement
builder/                                 cloud-init de la VM de build
scripts/                                 lib, doctor, VM de build, ISO, build, tests, déploiement
scripts/vm/                              scripts root (VM de build ou runner CI)
prompts/                                 textes de lancement
docs/                                    journal, notes ISO, rapport
cache/ out/ .builder/ reference/         non versionnés
```
