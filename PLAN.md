# Plan

Feuille de route de l'outil, tenue au fil de l'eau (consignes : `CLAUDE.md`).
Légende : `[ ]` à faire · `[x]` fait · `[!]` bloqué (raison dans `docs/JOURNAL.md`).
Une version n'est terminée que lorsque ses critères d'acceptation passent. Les changements visibles
vont dans `CHANGELOG.md`. Le plan de construction de la 0.1 (phases 0 à 5, 2026-11-07 et 08) est archivé
dans `docs/developpement/plan-v0.1.md`.

## 0.1.0-alpha — premier outil utilisable

Construction, tests et déploiement réalisés pendant les phases 0 à 5 ; clé déployée et utilisée depuis le
2026-11-08 (image `zorin-nomade-20261108-1009`, HP ProBook 455 G10).

### Retour d'expérience sur la clé déployée (2026-11-08, PR #1 `correctifs-cle`)

Mesures et constats : `docs/JOURNAL.md`. Branche préparée **sur la clé**, sans `make`, QEMU ni OVMF :
lint par shellcheck seul, puis CI GitHub.

- [x] Évaluation sur matériel réel : débits, latences, démarrage, mémoire, écritures, TRIM, services.
- [x] `deploy.sh` : essai de TRIM avec `blkdiscard -f </dev/null` et cause consignée (l'essai échouait
      sur toute clé déjà partitionnée quand stdin est un terminal) ; `deploy-test.sh` exige que l'essai
      réussisse à chaque passage.
- [x] D-041 : racine recréée avec `mkfs.ext4 -i $DEPLOY_INODE_RATIO` (64 Kio) ; contrôle d'autotest.
- [x] D-040 : `logind.conf.d/60-nomade.conf` (`RuntimeDirectorySize=25%`) ; contrôle d'autotest.
- [x] D-042 / E-43 : `secureboot-db.service`, `fwupd.service`, `fwupd-refresh.timer` masqués au build ;
      contrôles d'autotest.
- [x] README (Secure Boot et PC « Secured-core ») ; checklist du premier démarrage (veille, option
      MS UEFI CA).
- [x] Correctifs à chaud sur la clé (D-040, D-042, règle udev `provisioning_mode=unmap`,
      `DEPLOY_DISCARD=1`) ; GNOME Logiciels sans lancement automatique (`~/.config/autostart`).
      Vérifiés après redémarrage : unités masquées, `/run/user/1000` à 1,8 Gio, Logiciels absent.
- [x] Branche poussée, PR #1 ; CI `lint` et `image` vertes (`make test` : 107 contrôles, Secure Boot
      activé et désactivé ; accès à KVM rétabli après la construction).
- [x] Sur l'hôte : `make deploy-test RUNS=2` (absent de la CI) sur `outil-alpha` : « TRIM : essai
      réussi » aux deux passages, E-30 « racine recréée à 65536 octets par inode », 124 contrôles,
      `RESULT=PASS` Secure Boot activé et désactivé.
- [ ] Fusionner la PR #1.

### Le dépôt devient l'outil (D-044, branche `outil-alpha`)

- [x] `README.md` réécrit en mode d'emploi de l'outil (construire, tester, déployer, entretenir,
      dépanner, limites) ; checklist du premier démarrage dans `docs/premier-demarrage.md`.
- [x] Traces du chantier dans `docs/developpement/` : guide de développement, textes de lancement
      (`prompts/`), rapport du run autonome, plan de la 0.1.
- [x] `CLAUDE.md` recadré (maintenance et évolution de l'outil) ; `docs/A-FAIRE-FABIEN.md` à jour.
- [x] Version : `PROJECT_VERSION` (`config/project.env`), `CHANGELOG.md`, `NOMADE_VERSION` dans
      `/etc/nomade/build-info` (contrôle E-08), `DEPLOY_VERSION` dans `deploy-info`, version affichée
      par `make help`.
- [x] CI verte sur la PR #2 (`lint`, `image`).
- [ ] Fusion de la PR #2 après la PR #1.
- [ ] **Acceptation** : PR #1 et PR « outil » fusionnées, `make deploy-test` vert sur l'hôte ; Fabien pose
      l'étiquette `v0.1.0-alpha` sur `main` (`git tag -a v0.1.0-alpha -m … && git push --tags`) et date
      la version dans `CHANGELOG.md`.

## 0.2 — entretenir une clé déployée

Objectif : faire évoluer une clé en service sans la réécrire, et ne plus rien perdre quand un
redéploiement est nécessaire.

- [ ] Concevoir `nomade-update` (sur la clé) : appliquer les changements de `config/rootfs/` et des
      réglages du build (unités masquées ou désactivées, dconf, sysctl…) à un système déployé, de façon
      idempotente et contrôlée par l'autotest. Source : le dépôt cloné sur la clé ou une archive de la
      version ; décision à consigner.
- [ ] Redéploiement sans perte : au minimum sauvegarde et restauration de `/home` outillées et
      documentées ; au mieux, partition `/home` préservée (évolution de E-34, décision à prendre).
- [ ] Image : GNOME Logiciels sans service résident, sans écraser `/etc/xdg/autostart` du squashfs
      (méthode à choisir et à consigner).

## Plus tard

- [ ] Interface graphique Linux en Rust (GTK4 + libadwaita) par-dessus `make` et `deploy.sh`, avec un
      assistant privilégié lancé par `pkexec` qui garde les garde-fous de `lib.sh` (option A de
      l'évaluation du 2026-11-08) ; note de conception d'abord.
- [ ] Initramfs sans pilotes réseau de serveur ni leurs firmwares (≈ 30 Mo sur 83, ≈ 1 s de GRUB).
- [ ] rsyslog et avahi à couper (gains marginaux).
- [ ] Zorin 19 : refaire la simulation de D-014 et l'inspection de l'ISO (`docs/iso-notes.md`).
