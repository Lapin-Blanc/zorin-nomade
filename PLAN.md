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
- [x] PR #1 fusionnée (`ddf6458`).

### Le dépôt devient l'outil (D-044, branche `outil-alpha`)

- [x] `README.md` réécrit en mode d'emploi de l'outil (construire, tester, déployer, entretenir,
      dépanner, limites) ; checklist du premier démarrage dans `docs/premier-demarrage.md`.
- [x] Traces du chantier dans `docs/developpement/` : guide de développement, textes de lancement
      (`prompts/`), rapport du run autonome, plan de la 0.1.
- [x] `CLAUDE.md` recadré (maintenance et évolution de l'outil) ; `docs/A-FAIRE-FABIEN.md` à jour.
- [x] Version : `PROJECT_VERSION` (`config/project.env`), `CHANGELOG.md`, `NOMADE_VERSION` dans
      `/etc/nomade/build-info` (contrôle E-08), `DEPLOY_VERSION` dans `deploy-info`, version affichée
      par `make help`.
- [x] Utilisable par simple clonage (D-045) : `make doctor` sans faux échec (garde-fous Claude en
      avertissements, `STRICT=1`), `config/local.env.example`, clonage HTTPS dans le README.
- [x] CI verte sur la PR #2 (`lint`, `image`).
- [x] Déploiement réel par Fabien sur une clé SSK de 128 Go (2026-11-08) : déploiement en 3 min 57 s,
      démarrage et contrôles conformes. Pont VIA Labs `2109:0715` sans UAS ni TRIM : l'essai de TRIM est allé
      jusqu'au périphérique (`-f` efficace, vraie cause affichée), mais sa réussite depuis un vrai
      terminal reste à voir sur un pont qui accepte le TRIM.
- [x] `deploy.sh` : pilote USB détecté (`DEPLOY_USB_DRIVER` dans `deploy-info`), récapitulatif final
      adapté (pilote attendu, TRIM ou non, `rotational`).
- [x] PR #2 fusionnée après la PR #1 (`571a199`).
- [x] **Acceptation** : PR #1 et PR « outil » fusionnées, `make deploy-test` vert sur l'hôte ; étiquette
      `v0.1.0-alpha` posée sur `main` à la demande de Fabien (2026-11-08), version datée dans
      `CHANGELOG.md`. Réserve : « TRIM : essai réussi » depuis un vrai terminal reste à voir sur un pont
      qui accepte le TRIM.

## 0.2 — retours du terrain

Objectif : déployer sur des clés et des PC variés (clés SSK de 128 Go reformatables) et en tirer des
données comparables. Les tests grandeur nature qui suivront définiront les versions suivantes.

- [x] Version ouverte sur la branche `retours-terrain` : `PROJECT_VERSION=0.2.0-alpha`, section
      « Non publié » de `CHANGELOG.md`.
- [x] Note de conception `docs/developpement/conception-0.2.md` (`NOMADE-DATA`, `make diag-cle`,
      `nomade-diag`, `make diag-rapport`) : questions tranchées par Fabien (D-046 à D-049).
- [ ] Partition exFAT `NOMADE-DATA` active par défaut, à 10 % de la clé (`DEPLOY_DATA_PCT`, plancher
      8 Gio, `DEPLOY_DATA_GIB` en surcharge, 0 : aucune) ; montée par `fstab` sur `/media/NOMADE-DATA`
      (UUID, `uid=1000`, `nofail`), `exfatprogs` dans l'image ; autotest E-44 et `make deploy-test`
      (D-046). Sans effet sur la clé de 1 To (pas de redéploiement).
- [ ] `make diag-cle KEY=…` sur l'hôte, avant le déploiement : outil séparé de `deploy`, lecture seule
      par défaut (identification, lectures directes), analyse complète sur demande (`COMPLET=1`, efface
      la clé : capacité réelle, TRIM réel, écritures, `DUREE=1` min, cache SLC), SMART si `smartctl` ;
      verdict A–D et alertes ; `make diag-cle-test` dans la VM (contrefaçon simulée) (D-048).
- [ ] `nomade-diag` sur la clé (module Python commun avec `diag-cle`, D-047 ; lanceur dans le menu) :
      versions et autotest (`selftest.sh --materiel`), machine hôte
      (modèle, firmware, Secure Boot, « Microsoft UEFI CA » dans db, GPU), clé et pont USB (UAS, vitesse,
      TRIM, réinitialisations), temps de démarrage, mémoire et écritures, erreurs ; mesures de
      performance en option (écriture sur la racine, plafond 1 Gio). Anonymisé par défaut (numéros de série remplacés par une
      empreinte, ni MAC, ni IP, ni réseaux, ni noms). Archive `nomade-diag-<date>-<modèle>.tar.zst`
      avec `resume.json` stable, écrite sur `NOMADE-DATA` si elle existe.
- [ ] Côté hôte : `make diag-rapport` rassemble les `resume.json` (`diagnostics/resumes/` et
      `docs/terrain.md` versionnés, archives hors de git, D-049) en un tableau comparatif ; `deploy.sh`
      affiche le verdict du dernier `diag-cle` et transmet empreinte et sel.
- [ ] Image : GNOME Logiciels sans service résident, sans écraser `/etc/xdg/autostart` du squashfs
      (méthode à choisir et à consigner).

## Entretenir une clé déployée (sans version prévue)

Au second plan : les tests grandeur nature (0.2 et suivantes) feront encore évoluer la base et
décideront des prochaines versions. À reprendre quand elle se sera stabilisée.

- [ ] Concevoir `nomade-update` (sur la clé) : appliquer les changements de `config/rootfs/` et des
      réglages du build (unités masquées ou désactivées, dconf, sysctl…) à un système déployé, de façon
      idempotente et contrôlée par l'autotest. Source : le dépôt cloné sur la clé ou une archive de la
      version ; décision à consigner.
- [ ] Redéploiement sans perte : au minimum sauvegarde et restauration de `/home` outillées et
      documentées ; au mieux, partition `/home` préservée (évolution de E-34, décision à prendre).

## Plus tard

- [ ] Interface graphique Linux en Rust (GTK4 + libadwaita) par-dessus `make` et `deploy.sh`, avec un
      assistant privilégié lancé par `pkexec` qui garde les garde-fous de `lib.sh` (option A de
      l'évaluation du 2026-11-08) ; note de conception d'abord.
- [ ] Initramfs sans pilotes réseau de serveur ni leurs firmwares (≈ 30 Mo sur 83, ≈ 1 s de GRUB).
- [ ] rsyslog et avahi à couper (gains marginaux).
- [ ] Zorin 19 : refaire la simulation de D-014 et l'inspection de l'ISO (`docs/iso-notes.md`).
