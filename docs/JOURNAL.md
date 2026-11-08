# Journal

Entrées courtes, les plus récentes en bas. Format : `## AAAA-MM-JJ HH:MM — phase / sujet`,
puis ce qui a été fait, ce qui a échoué et pourquoi, et la suite prévue.

## 2026-11-07 — base du projet
Archive de départ préparée avec Fabien : documentation, VM de build, harnais de test,
overlay de configuration, autotest. Scripts de build et de déploiement à écrire (phases 1 et 3).

## 2026-11-07 11:10 — phase 0 / hôte et dépôt
`make doctor` : outils, KVM, OVMF, espace (111 Gio) en ordre ; [KO] attendu sur les groupes
`docker`/`libvirt`, gardés par Fabien (D-019). `.claude/settings.json` sans règles `deny`
(laissé tel quel). Hôte à 7 Gio de RAM → VM ramenées à 3 Gio (D-016). `git init` (identité
locale « Fabien Toune », noreply GitHub), commit de base fidèle à l'archive.

## 2026-11-07 11:15 — phase 0 / référence Debian
Lu (pendant le téléchargement) `docs/lecons.md`, `architecture.md`, `construire-image.sh`,
`tester-image.sh`, `image.yml`. Conventions reprises ou écartées : D-015. CI complète retenue
avec Fabien (D-023).

## 2026-11-07 11:20 — phase 0 / ISO et VM de build
Dernière ISO : Zorin OS 18.1 Core (2026-04-14), empreinte relevée sur la page d'aide Zorin et
recoupée avec le miroir (D-013). `make iso` : 7 min 30, empreinte vérifiée. `make builder` : 2 min
(image cloud + cloud-init `done`), 94 Gio libres dans la VM, tous les outils présents. Copie de
l'ISO dans la VM : 22 s. Piège de méthode : une boucle `until ! pgrep -f fetch-iso.sh` se trouve
elle-même (le motif est dans sa propre ligne de commande) : attendre sur le PID, ou `pgrep -x`.

## 2026-11-07 11:45 — phase 0 / inspection de l'ISO
Schéma Ubiquity à couche unique (`filesystem.squashfs` + `manifest-remove` de 255 paquets),
noyau 6.17.0-20 (7.0.0-42 après mise à jour), Brave au lieu de Firefox, snapd sans snap, Tracker 3.7,
pas de profil dconf `user`, os-prober actif par défaut, `resolv.conf` en lien vers `/run` (premier
essai de simulation sans DNS pour cette raison). Simulation APT en chroot : 231 purges sans
cascade, `full-upgrade` de ≈ 1,7 Go. Détails : `docs/iso-notes.md`. Clés dconf corrigées
(Tracker, D-020) et validées par `gsettings` dans le chroot ; `GRUB_DISABLE_OS_PROBER=true` (D-026).

## 2026-11-07 11:50 — phase 0 / décisions avec Fabien et plan
Brave + définition psd (D-021, E-25), mises à jour de sécurité auto gardées (D-022), census retiré
(D-025, E-39), quatre services désactivés (D-024, E-40), CI complète (D-023, E-42). SPEC, PLAN
(phases 1 à 5) et `docs/A-FAIRE-FABIEN.md` mis à jour. Fin de la phase 0 : arrêt pour validation.
La VM de build est arrêtée (disque et ISO conservés dans `/work/iso`).

## 2026-11-07 19:00 — phase 1 / premier build
Scripts écrits : `config/packages/*.list`, `scripts/vm/build.sh` (root, VM ou CI), `scripts/build-image.sh`
(orchestration, rapatriement creux en flux zstd), contrôle mémoire de `test-image.sh` (D-016).
Avant le run, RAM libérée sur l'hôte (Brave, VS Code, GNOME Logiciels fermés, accord de Fabien).
Essai de `grub-install` en chroot jetable : pas de `--force-extra-removable` sous Ubuntu, `grubx64.efi`
absent de `EFI/BOOT` → script de synchronisation + crochet APT (D-029).
1er build : échec au contrôle EFI (dossier inattendu) ; noyau 6.17 non retiré par `autoremove`
(purge explicite ajoutée). 2e build : passe ; `make test` : écran de connexion GNOME atteint avec
Secure Boot activé et désactivé (≈ 1 min chacun).

## 2026-11-08 00:40 — phase 1 / corrections et sonde des mises à jour
Analyse du dossier `EFI/grub` : `/etc/default/grub` supprimé par la purge de `grub-pc` → restauré
(D-032), retour à `EFI/ubuntu` et au menu « Zorin ». Le cache APT était vidé par `apt-get clean`
avant démontage → corrigé. Faux échec E-10 sans Secure Boot (variable absente lue « unknown ») →
corrigé dans l'autotest. Sonde (choix b de Fabien) sur une copie jetable de l'image dans la VM :
réinstallation de shim et GRUB par APT → `EFI/BOOT` reste cohérent, mais `grub-install` tente
d'écrire en NVRAM (update_nvram ignoré) → déviation de `grub-install` vers une enveloppe
`--no-nvram` et mise à jour simulée intégrée au build, bloquante (D-033).

## 2026-11-08 09:00 — phase 1 / acceptation
Build en 5 min (cache APT réutilisé), image de 6,8 Gio alloués / 28 Gio. `make test` : les deux
essais atteignent `graphical.target` et l'écran de connexion GNOME (captures vérifiées), 48 PASS
chacun ; restent E-21 (`/tmp` en tmpfs) et E-26 (dconf), prévus en phase 2. Journal `-p err` vide.
Phase 1 terminée. Note : mémoire de l'hôte de nouveau juste (2,8 Gio libres après arrêt de la VM
de build), l'essai a quand même tenu.

## 2026-11-08 09:45 — phase 2 / réglages et autotest
Ajouts au build : `tmp.mount` (D-038), psd global, profil dconf `user` + `dconf update` (valeurs
relues par `gsettings` au build), E-40 (`systemctl disable`), `check-language-support -l fr` (rien à
installer), manifeste copié dans `/etc/nomade/packages.manifest`. Overlay : définition psd Brave,
profil dconf, `conf.d/60-nomade-keymap`. Autotest étendu (E-04, E-08, E-09 complet, E-11, E-15, E-17,
E-20, E-22, E-25 à E-27, E-39 à E-41) et contrôles « clé déployée » pour la phase 3.
Trois faux départs : (1) lien psd absolu testé par `-e` hors chroot → `-L` ; psd était déjà activé
globalement par son paquet ; (2) `lsinitramfs | grep -q` sous `pipefail` (SIGPIPE) → variable ;
(3) `KEYMAP=y` sans effet sous Ubuntu, le crochet `console_setup` embarque toujours la disposition →
contrôle sur `cached_UTF-8_del.kmap.gz` (D-034). `whoopsie.service` est « static » (déclenché par
`whoopsie.path`) : l'autotest l'admet s'il est inactif.

## 2026-11-08 09:56 — phase 2 / acceptation
Build en 10 min, image 6,8 Gio alloués. `make test` : `RESULT=PASS` avec Secure Boot activé et
désactivé, 103 contrôles chacun, journal `-p err` vide, écran de connexion GNOME (en français).
Phase 2 terminée. Les contrôles « clé déployée » sont en place pour la phase 3.

## 2026-11-08 10:10 — phase 3 / déploiement
`scripts/deploy.sh` (recréation LUKS2 + rsync, D-035 ; détails D-036), `scripts/deploy-test.sh`,
`test-image.sh --encrypted` (question détectée par l'inactivité du disque, D-037). 1er essai : faux
échec sur les drapeaux LUKS (tabulation dans la sortie de `luksDump`) → blancs normalisés. 2e essai
(image de la phase 2) : déploiement en 2 min 44 s dans la VM, fichier rapatrié 7,9 Gio alloués / 64 ;
question LUKS détectée à ≈ 22 s, phrase tapée en touches AZERTY (`a`→`q`, `z`→`w`, `m`→`;`) et
acceptée en 3 s : disposition `be` prouvée dans l'initramfs ; 117 PASS, seule la ligne des drapeaux
échouait (même bug d'analyse, dans l'autotest embarqué) → reconstruction de l'image et essai final
avec deux déploiements successifs (E-34).

## 2026-11-08 10:35 — phase 3 / acceptation
Image reconstruite (autotest corrigé), puis `make deploy-test RUNS=2` : deux déploiements successifs
sur le même fichier de 64 Gio (2 min 53 s et 3 min 26 s ; deux volumes LUKS2 d'UUID différents :
clé de volume tirée à chaque fois ; TRIM accepté → règle `unmap`), fichier rapatrié 7,9 Gio alloués.
Démarrage : question détectée à 24 s, phrase acceptée en 3 s (touches AZERTY), `RESULT=PASS` avec
Secure Boot activé et désactivé, 118 contrôles (racine dm-crypt, drapeaux LUKS persistants,
`discard`, règle udev appliquée, racine agrandie, compte déverrouillé). Aucun secret dans les
journaux (contrôlé par `deploy-test.sh`). Phase 3 terminée.

## 2026-11-08 10:40 — phase 4 / CI
`image.yml` : déclenché par `scripts/**`, `config/**`, `Makefile`, le workflow, et à la demande ;
espace libéré, outils, KVM (règle udev), `make ci`, ISO en `actions/cache` (restauration puis
enregistrement immédiat après téléchargement), `sudo scripts/vm/build.sh` sur le runner (shell
`bash -eo pipefail` pour que `| grep` ne masque pas un échec), `make test`, synthèse dans le résumé
du job, artefact `diagnostic` (journaux, série, captures, manifeste ; pas d'image). `lint.yml` lance
`make ci`, qui ajoute `scripts/test-guards.sh` (16 refus attendus des garde-fous, sans root).
Validation locale : YAML chargé, étapes `run` passées à shellcheck (`actionlint` absent de l'hôte).
Pas de dépôt GitHub : rien n'est poussé ; marche à suivre dans `docs/A-FAIRE-FABIEN.md`.

## 2026-11-08 10:55 — phase 5 / reproductibilité, premier essai
Clone propre dans un dossier temporaire profond, VM détruite : construction depuis zéro réussie
(VM neuve, cache APT vide, ≈ 15 min), mais les deux essais QEMU échouent en 3 s : le chemin du socket
QMP (`out/test/sb-on/qmp.sock` sous un chemin long) dépasse la limite de 108 octets des sockets Unix.
Défaut invisible dans le dépôt principal (chemin court). Correction : sockets dans
`$XDG_RUNTIME_DIR/nomade-qmp.XXXXXX`. Chaîne complète relancée depuis le clone mis à jour.

## 2026-11-08 11:15 — phase 5 / acceptation et rapport
Clone propre mis à jour (`6b00b2d`), `make builder-destroy && make all` : 19 min 26 s, VM neuve, build
en 13 min avec cache APT vide, `RESULT=PASS` (103 contrôles) avec et sans Secure Boot. E-38 tenue.
Clone et sa VM supprimés ; la VM du dépôt principal aussi (recréée au prochain `make image`).
`docs/RAPPORT.md` écrit (résultats, déviations, limites, checklist du premier démarrage natif).
Contrôle de présence de l'ISO dans la VM rendu silencieux (message « FAILED open or read »
trompeur). Fin du run autonome : phases 0 à 5 terminées.
