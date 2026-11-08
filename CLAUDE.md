# zorin-nomade — consignes pour Claude Code

zorin-nomade est un **outil** (version `PROJECT_VERSION` dans `config/project.env`, historique dans
`CHANGELOG.md`) qui construit et déploie un **Zorin OS 18.x Core installé (pas un live)** sur une clé
USB SSK (SSD NVMe derrière un pont USB), démarrable sur n'importe quel PC UEFI. Il est utilisé au
quotidien : tu le **maintiens et le fais évoluer** sans casser ce qui marche.
Le système cible est décrit dans `SPEC.md` ; la feuille de route dans `PLAN.md` ; le mode d'emploi
dans `README.md` ; la façon de développer dans `docs/developpement/README.md`.
Ce fichier dit **comment** travailler.

Langue du projet : **français** (documentation, commentaires, messages de commit, journal).

## Architecture du pipeline

```
Hôte (Zorin, utilisateur normal, SANS root)          VM de build jetable (Ubuntu 24.04 cloud)
───────────────────────────────────────────          ─────────────────────────────────────────
Claude Code, dépôt git, cache/, out/                  root disponible (sudo sans mot de passe)
make builder  ──── crée/démarre ───────────────────▶  QEMU utilisateur, SSH sur 127.0.0.1:2222
./scripts/bssh <cmd>  ──── SSH ───────────────────▶  loop devices, partitionnement, unsquashfs,
./scripts/builder.sh push|pull  ── tar sur SSH ───▶  chroot, grub-install, mkfs…
make test  (QEMU + OVMF sur l'hôte, sans root)  ◀──  out/*.img rapatriée
```

- **Tout ce qui demande root se fait dans la VM de build**, via `./scripts/bssh sudo …`.
- **Sur l'hôte, tu n'as pas root et tu ne le cherches pas.** Aucun `sudo`, `su`, `pkexec`
  (les règles `deny` de `.claude/settings.json` le bloquent de toute façon).
- Le test de l'image (`make test`) tourne **sur l'hôte**, sans root : QEMU + KVM + OVMF,
  la clé étant simulée en **USB** (`qemu-xhci` + `usb-storage`), NVRAM vierge à chaque essai,
  Secure Boot activé puis désactivé. Pas de virtualisation imbriquée nécessaire.
- La VM de build est **jetable** : `make builder-destroy && make builder` doit toujours
  reconstruire un environnement fonctionnel. Rien d'important ne doit vivre uniquement dans la VM.

## Règles de sécurité (non négociables)

1. **Jamais de déploiement sur un vrai périphérique.** `make deploy` / `scripts/deploy.sh`
   visant `/dev/disk/by-id/…` est réservé à Fabien. Tu testes le déploiement **uniquement**
   dans la VM de build, sur un fichier image ou un loop device (`make deploy-test`).
2. **Jamais de root sur l'hôte**, jamais de modification de la configuration système de l'hôte
   (paquets, groupes, GRUB, NVRAM, udev). S'il manque un paquet sur l'hôte, consigne-le
   dans `docs/A-FAIRE-FABIEN.md` et contourne si possible (en faisant le travail dans la VM).
3. **Aucune donnée secrète dans les artefacts.** La clé de volume LUKS est générée au déploiement,
   sur la cible ; jamais dans une image, un dépôt, un journal ou la CI. Les phrases de passe
   de test ne servent qu'en mode test et ne laissent aucune trace dans le système déployé.
4. Le dossier `reference/` (copie jetable du projet Debian de Fabien) est **en lecture seule** :
   tu t'en inspires, tu n'y écris pas, tu n'y lances rien.
5. Les fonctions de garde de `scripts/lib.sh` (`assert_real_usb_target`, `assert_test_target`)
   sont **obligatoires** dans tout script qui écrit sur une cible. Ne les affaiblis pas.

## Autonomie

- En **run autonome**, ne pose aucune question : prends la décision la plus raisonnable,
  consigne-la dans `DECISIONS.md` (format existant, une entrée par décision), et continue.
- En **travail interactif** (retouches, ou phase d'inspection avant un chantier), tu peux poser des
  questions à Fabien ; pour un chantier, arrête-toi sur une synthèse avant de lancer le plan.
- Si un problème résiste à **3 tentatives** sur la même piste : écris l'analyse dans
  `docs/JOURNAL.md`, change d'approche (en respectant les priorités de `SPEC.md`).
  Si c'est vraiment bloquant, marque la tâche `[!]` dans `PLAN.md`, explique pourquoi,
  et avance sur ce qui n'en dépend pas.
- Tu peux modifier `PLAN.md` (affiner, découper, réordonner) ; toute **déviation par rapport
  à `SPEC.md`** doit être justifiée dans `DECISIONS.md`.

## Mémoire de travail (le contexte peut être compacté)

- `PLAN.md` : cases à cocher `[ ]` / `[x]` / `[!]`. Coche **au fil de l'eau**.
- `docs/JOURNAL.md` : entrées courtes et datées (ce qui a été fait, ce qui a échoué, pourquoi).
- `DECISIONS.md` : décisions et déviations.
- `docs/iso-notes.md` : ce que la phase 0 a appris de l'ISO (structure, paquets, pièges).
- `CHANGELOG.md` : tout changement visible (image, déploiement, commandes, paramètres) va sous
  « Non publié ». Une version se publie selon `docs/developpement/README.md` ; ne pose jamais
  d'étiquette git sans la demande de Fabien.
- Après une compaction ou une reprise, **relis ces fichiers** avant d'agir.
- **Commit git à chaque étape terminée** (message en français, impératif : « Ajoute… »,
  « Corrige… »). Ne committe jamais `cache/`, `out/`, `.builder/`, `reference/`.

## Conventions de code

- Bash : `#!/usr/bin/env bash`, `source` de `scripts/lib.sh` (qui active
  `set -Eeuo pipefail`), fonctions courtes, **idempotence** (relancer ne casse rien),
  journalisation via `log` / `warn` / `die`.
- `make lint` (shellcheck) doit passer avant chaque commit.
- Paramètres dans `config/project.env` (et `config/iso.env`) — pas de valeurs en dur
  dispersées. Surcharges locales éventuelles : `config/local.env` (non versionné).
- Les fichiers à copier dans le système cible vivent dans `config/rootfs/` (overlay).
  **N'écrase jamais à l'aveugle un fichier existant du squashfs** : s'il existe, fusionne
  et consigne la fusion dans `docs/iso-notes.md`.
- Python autorisé pour l'outillage de test si c'est plus clair (toujours `python3 -I`).

## Commandes longues

- Téléchargements, build, tests QEMU : lance-les **en arrière-plan** avec sortie dans
  `out/logs/<étape>.log`, puis suis l'avancement (`tail`, `grep`). Ne déverse pas de longs
  journaux dans la conversation : filtre (`grep -a NOMADE-SELFTEST`, `tail -n 50`).
- Le résultat d'un test se lit dans `out/test/<essai>/serial.log` (lignes `NOMADE-SELFTEST:`)
  et la capture d'écran `out/test/<essai>/screen.png` (tu peux l'ouvrir pour vérifier
  que l'écran de connexion GNOME s'affiche).
- Si tu tournes **sur une clé nomade** (`/etc/nomade/deploy-info` existe), `make`, QEMU et OVMF y
  sont absents : lint par shellcheck extrait sans root, construction et tests par la CI,
  `make deploy-test` laissé à l'hôte (`docs/developpement/README.md`). Sur la clé, la règle « jamais
  de root » vaut comme sur l'hôte : les changements système passent par un script que Fabien lance.

## Commandes utiles

```
make help                 # liste des cibles
make doctor               # vérifie l'hôte (outils, KVM, OVMF, garde-fous, espace)
make builder              # démarre (ou crée) la VM de build
./scripts/bssh <cmd>      # commande dans la VM (ex. ./scripts/bssh sudo lsblk)
./scripts/builder.sh push <chemin-hôte> <dossier-vm>
./scripts/builder.sh pull <chemin-vm> <dossier-hôte>
make iso / image / test / deploy-test / all
make builder-destroy      # jette la VM (le cache est conservé)
```
