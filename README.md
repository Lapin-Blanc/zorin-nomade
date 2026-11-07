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
                 bmap-tools cryptsetup exfatprogs
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
restent appliquées dans ce mode (pas de `sudo`, pas de `dd`, pas de `make deploy`…), et
Claude n'a de toute façon pas root sur l'hôte.

Si la limite d'usage coupe le run :
```bash
claude --continue --dangerously-skip-permissions
```
puis « Relis PLAN.md, DECISIONS.md et docs/JOURNAL.md, et continue le plan. »

## 5. Après le run

```bash
make test-gui                     # démarre la dernière image dans une fenêtre, pour regarder
ls -l /dev/disk/by-id/ | grep usb # repère ta clé SSK (le disque entier, sans « -part »)
sudo make deploy KEY=/dev/disk/by-id/usb-…
```
Le déploiement affiche modèle, numéro de série et taille de la clé et te demande de **taper
le numéro de série** avant d'écrire quoi que ce soit. Il te demande ensuite la phrase de passe
LUKS et le mot de passe de ton compte. La checklist du premier démarrage natif est dans
`docs/RAPPORT.md`.

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
scripts/                                 lib, doctor, VM de build, ISO, tests (+ build et déploiement écrits par Claude)
prompts/                                 textes de lancement
docs/                                    journal, notes ISO, rapport
cache/ out/ .builder/ reference/         non versionnés
```
