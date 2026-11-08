# Développer zorin-nomade

Le projet est écrit et maintenu avec Claude Code. Ce guide dit comment le faire évoluer et d'où il
vient. Les règles de travail elles-mêmes sont dans `CLAUDE.md`, à la racine, lu automatiquement par
Claude Code.

## Mémoire du projet

| Fichier | Rôle |
|---|---|
| `SPEC.md` | système visé, exigences numérotées E-xx ; toute déviation se justifie dans `DECISIONS.md` |
| `DECISIONS.md` | une entrée par décision (D-nnn), jamais effacée : une décision abandonnée est « remplacée par » |
| `PLAN.md` | feuille de route : version en cours, version suivante, plus tard |
| `CHANGELOG.md` | changements visibles, par version |
| `docs/JOURNAL.md` | journal daté : ce qui a été fait, ce qui a échoué, pourquoi |
| `docs/iso-notes.md` | constats sur l'ISO Zorin (structure, paquets, pièges) |
| `docs/A-FAIRE-FABIEN.md` | ce que Claude ne peut pas faire lui-même (root sur l'hôte, GitHub…) |

## Faire évoluer l'outil

**Retouche** (cas courant), depuis le terminal (`claude`) ou VS Code (extension Claude Code, mêmes
`CLAUDE.md` et règles) : décrire le changement voulu et demander que `SPEC.md` (si une exigence change),
`DECISIONS.md`, l'autotest et `CHANGELOG.md` suivent, puis `make lint` et `make all` (et
`make deploy-test` si le déploiement change). L'extension VS Code démarre par défaut en mode auto,
adapté aux retouches ; le mode « Bypass permissions » n'y apparaît qu'après avoir activé
**Allow dangerously skip permissions** dans ses réglages.

**Chantier plus large** (nouvelle version de Zorin, refonte), sur le modèle de la 0.1 : une phase
interactive pour inspecter et décider, puis un run autonome sur un plan écrit dans `PLAN.md` :
```bash
claude --model opus --effort high --dangerously-skip-permissions
```
Après une coupure : `claude --continue --dangerously-skip-permissions`, puis « Relis PLAN.md,
DECISIONS.md et docs/JOURNAL.md, et continue le plan. » Les textes de lancement de la 0.1 servent de
modèles : `prompts/phase0.md`, `prompts/run.md`, `prompts/reprise-vscode.md`.

**Depuis une clé nomade** : le dépôt peut être cloné et modifié sur la clé, mais ni `make`, ni QEMU, ni
OVMF n'y sont installés. Le lint se fait avec un shellcheck extrait sans root du paquet Ubuntu
(`apt-get download shellcheck`, `dpkg-deb -x`) ; la CI GitHub construit et teste ; `make deploy-test`
reste à lancer sur l'hôte (voir `docs/JOURNAL.md`, 2026-11-08).

## Sécurité de l'hôte

Claude Code n'a jamais root sur la machine de développement : tout ce qui en demande passe par la VM de
build (`./scripts/bssh sudo …`), et le déploiement réel est réservé à Fabien (`sudo make deploy`). Les
garde-fous de `scripts/lib.sh` (`assert_real_usb_target`, `assert_test_target`) sont obligatoires dans
tout script qui écrit sur une cible ; `make ci` vérifie qu'ils refusent ce qu'ils doivent refuser.

`make doctor` contrôle aussi que Claude ne pourrait pas obtenir root par un détour : pas de `sudo` sans
mot de passe, compte hors des groupes `disk`, `docker`, `lxd`, `incus-admin` (`libvirt` à part).
Ces points ne concernent pas l'usage de l'outil : ce sont des avertissements `[!!]`, et
`make doctor STRICT=1` les rend bloquants, avant une session de Claude Code en mode sans confirmation. Le compte de Fabien reste dans `docker` et `libvirt` et les règles `deny` de
`.claude/settings.json` sont inactives (D-019) : seules les consignes de `CLAUDE.md` protègent alors
l'hôte en mode sans confirmation.

`reference/debian` (non versionné) est une copie jetable du projet Debian de Fabien, en lecture seule
pour Claude : `git clone --depth 1 /chemin/vers/le-projet-debian reference/debian`.

## Versions

- Numérotation `MAJEUR.MINEUR.CORRECTIF[-alpha|-beta]` ; la version courante est `PROJECT_VERSION`
  dans `config/project.env`. Elle est inscrite dans l'image (`/etc/nomade/build-info`,
  `NOMADE_VERSION`) et sur la clé déployée (`/etc/nomade/deploy-info`, `DEPLOY_VERSION`).
- Pendant le travail, les changements s'accumulent sous « Non publié » dans `CHANGELOG.md`.
- Publier une version : `make lint`, CI verte, `make deploy-test` vert ; dater la section dans
  `CHANGELOG.md` ; puis, sur `main`, `git tag -a v<version> -m "zorin-nomade <version>"` et
  `git push --tags` (étiquette posée par Fabien ou à sa demande). Passer ensuite `PROJECT_VERSION` à la
  version suivante. L'image n'est pas publiée (D-043).

## Histoire de la version 0.1 (2026-11-07 et 08)

Le dépôt est parti d'une archive de base (consignes, spécification, plan, squelette de scripts) :
- **phase 0**, interactive : inspection de l'ISO, décisions D-013 à D-028, plan ajusté
  (`prompts/phase0.md`) ;
- **run autonome**, phases 1 à 5 : image, réglages et autotest, déploiement chiffré, CI,
  reproductibilité (`prompts/run.md`, `prompts/reprise-vscode.md`) ; rapport :
  `rapport-run-autonome.md` ; plan : `plan-v0.1.md` ;
- **retour d'expérience** sur la clé déployée et passage du dépôt en outil (PR #1 et PR « outil »,
  `docs/JOURNAL.md`).

Les textes de `prompts/` et le rapport citent l'organisation de l'époque (`prompts/` et
`docs/RAPPORT.md` à la racine du dépôt).
