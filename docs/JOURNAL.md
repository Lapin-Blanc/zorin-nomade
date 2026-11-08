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
