# Plan

Légende : `[ ]` à faire · `[x]` fait · `[!]` bloqué (raison dans `docs/JOURNAL.md`).
Chaque phase se termine par `make lint` propre et un commit. Les critères d'acceptation
sont **vérifiables** : une phase n'est terminée que lorsqu'ils passent.

## Phase 0 — État des lieux (interactive, effort xhigh)

- [ ] Lire `CLAUDE.md`, `SPEC.md`, `DECISIONS.md`, `README.md`.
- [ ] Initialiser git si nécessaire (commit initial de la base).
- [ ] `make doctor` ; reporter dans `docs/A-FAIRE-FABIEN.md` ce qui manque sur l'hôte.
- [ ] Parcourir `reference/debian` (si présent) : relever les conventions utiles (Makefile,
      VM de création, CI/CD, tests, journalisation) et les adopter quand elles conviennent
      (décisions dans `DECISIONS.md`). Ne rien y écrire.
- [ ] Trouver la dernière ISO **Zorin OS 18.x Core** officielle et son SHA-256 publié par Zorin ;
      remplir `config/iso.env` (avec la source de l'empreinte). `make iso`.
- [ ] `make builder` ; vérifier SSH, cloud-init, espace disque dans la VM.
- [ ] Inspecter l'ISO dans la VM et consigner dans `docs/iso-notes.md` :
      - organisation des squashfs (couche unique ou couches à empiler, ordre, fichiers
        de description) ;
      - paquets à retirer après installation (manifeste « remove » ou équivalent) ;
      - où se trouvent `shim-signed`, `grub-efi-amd64-signed`, les paquets de langue
        (squashfs ? pool de l'ISO ? réseau ?) ;
      - noyau, initramfs-tools, présence de snapd et de snaps, profil dconf existant,
        nom du paquet de l'installateur Zorin ;
      - disponibilité de `systemd-zram-generator` et `profile-sync-daemon`.
- [ ] Ajuster les phases 1 à 5 ci-dessous selon ces constats.
- [ ] **S'arrêter** et présenter à Fabien : constats, décisions, plan ajusté, points ouverts.

## Phase 1 — Image minimale qui démarre

- [ ] `scripts/build-image.sh` (orchestration depuis l'hôte) + scripts exécutés dans la VM
      (par ex. `scripts/vm/…`), idempotents, journalisés dans `out/logs/build-*.log`.
- [ ] Image creuse, GPT selon E-06, systèmes de fichiers, montage.
- [ ] Décompression du ou des squashfs (E-03), purge des éléments live (E-02).
- [ ] Chroot : fstab (E-07), hostname, utilisateur verrouillé (E-17), locale/clavier/fuseau
      (E-15, E-16), noyau + initramfs (E-12), shim + GRUB amovible sans NVRAM (E-09, E-11).
- [ ] Copie de l'overlay `config/rootfs/`, écriture de `/etc/nomade/*` (E-08), activation
      de `nomade-selftest.service`.
- [ ] Artefacts `out/` (E-05), rapatriement sur l'hôte (`builder.sh pull`, en préservant le creux).
- [ ] **Acceptation** : `make test` → les deux essais (Secure Boot on/off) atteignent
      `graphical.target`, la capture montre l'écran de connexion GNOME.

## Phase 2 — Réglages et autotest complet

- [ ] Appliquer E-13, E-14, E-18 à E-27 (fusionner proprement avec l'existant du squashfs).
- [ ] `apt full-upgrade`, paquets de langue (E-15), manifeste (E-04).
- [ ] Compléter `config/rootfs/usr/local/lib/nomade/selftest.sh` pour couvrir E-36
      (une ligne par exigence vérifiable).
- [ ] **Acceptation** : `make test` → `RESULT=PASS` avec Secure Boot activé **et** désactivé.

## Phase 3 — Déploiement

- [ ] `scripts/deploy.sh` selon E-28 à E-34 (garde-fous de `lib.sh` obligatoires).
- [ ] `scripts/deploy-test.sh` : exécution dans la VM vers un fichier creux de 64 Gio (E-37),
      rapatriement, démarrage QEMU avec déverrouillage LUKS automatisé propre au test
      (méthode au choix : saisie scriptée via QMP/série, etc. — à documenter).
- [ ] Étendre `scripts/test-image.sh` si nécessaire (option pour une image chiffrée).
- [ ] **Acceptation** : `make deploy-test` → `RESULT=PASS`, racine sur `dm-crypt`,
      `crypttab` avec `discard`, drapeaux de performance LUKS persistants, utilisateur
      déverrouillé, règle udev générée (VID:PID du test).

## Phase 4 — CI

- [ ] Aligner sur la CI du projet Debian si `reference/debian` en contient une ; sinon garder
      `.github/workflows/lint.yml` (lint + vérifications rapides).
- [ ] Documenter dans `README.md` ce qui tourne en CI et ce qui reste local (build complet,
      tests QEMU).
- [ ] **Acceptation** : `make ci` passe localement.

## Phase 5 — Reproductibilité et rapport

- [ ] `make builder-destroy && make all` depuis un clone propre (E-38).
- [ ] `docs/RAPPORT.md` : ce qui a été fait, déviations, limites connues, durée et taille
      des artefacts, **checklist du premier démarrage natif** pour Fabien (Wi-Fi, son,
      `lsusb -t` → `uas`, `lsblk --discard`, `fstrim -v /`, `swapon`, session GNOME,
      démarrage sur un PC Secure Boot et un PC sans).
- [ ] Mettre à jour `README.md` si l'usage a changé.
