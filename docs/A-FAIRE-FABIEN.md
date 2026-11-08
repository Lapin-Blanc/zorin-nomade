# À faire de ton côté

Tenu à jour par Claude : ce qu'il ne peut pas faire lui-même (root sur l'hôte, matériel réel,
décisions). Dernière mise à jour : 2026-11-08.

## En cours : version 0.1.0-alpha

1. **Sur l'hôte** (Zorin interne) : récupérer la branche de la PR #1 et lancer le test de déploiement,
   absent de la CI :
   ```bash
   git fetch && git switch correctifs-cle && make deploy-test
   ```
   Vérifier « TRIM : essai réussi » aux deux passages et la ligne E-30 « racine recréée à 65536 octets
   par inode » ; puis fusionner la PR #1, puis la PR « outil » (`outil-alpha`).
2. **Étiqueter la version** sur `main` une fois tout vert : dater la section 0.1.0-alpha de
   `CHANGELOG.md`, puis `git tag -a v0.1.0-alpha -m "zorin-nomade 0.1.0-alpha" && git push --tags`
   (ou demande-le à Claude).
3. **Sur la clé**, points restants de `docs/premier-demarrage.md` : son, second écran, recherche par
   nom, mise en veille, première `apt full-upgrade` (puis `sudo ls /boot/efi/EFI/BOOT`), essai sur un
   PC avec Secure Boot actif (option « MS UEFI CA » si refus).

## État de l'hôte

- `make doctor` (2026-11-07) : outils, KVM, OVMF, espace disque en ordre.
- **Groupes `docker` et `libvirt`** gardés (D-019) : `make doctor` affiche `[KO]` sur ce point, c'est
  attendu. Pour revenir dessus : `sudo gpasswd -d fabien docker` (et `libvirt`), puis reconnexion.
- **Règles `deny` inactives** : `.claude/settings.json` ne contient que `allow: Bash(*)`, et la copie des
  règles d'origine a été supprimée (commit `c1bb566`). Pour les retrouver :
  `git show c1bb566^:".claude/settings copy.json"`, puis fusionner le bloc `deny` dans `settings.json`.
- **Mémoire** : 7 Gio. VM de build et VM de test à 3 Gio (D-016) ; pendant `make all`, fermer quelques
  onglets aide.

## GitHub

- Dépôt `Lapin-Blanc/zorin-nomade` (public), CI active : `lint` à chaque push, `image` (construction et
  `make test`) sur les changements de scripts ou de configuration. Premier run vert le 2026-11-08 après
  correction de l'accès à KVM. Aucun secret nécessaire : la CI ne déploie rien.

## Pont USB de la clé

- Pont SSK `090c:2320` en UAS sur le HP ProBook : aucune réinitialisation constatée à l'usage (2026-11-08). En
  cas de déconnexions (`uas_eh` dans le journal du noyau) : quirk `usb-storage.quirks=090c:2320:u`
  (perd UAS et TRIM).
