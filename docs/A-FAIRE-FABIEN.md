# À faire de ton côté

Tenu à jour par Claude : ce qu'il ne peut pas faire lui-même (root sur l'hôte, matériel réel,
décisions). Dernière mise à jour : 2026-11-08.

## En cours : version 0.2.0-alpha (branche `retours-terrain`)

1. **Valider la note de conception** `docs/developpement/conception-0.2.md` (`NOMADE-DATA` par défaut,
   `make diag-cle` avant déploiement, `nomade-diag` après, `make diag-rapport`) : questions ouvertes en fin de note. Rien n'est codé avant.
2. **Sur la clé de 1 To**, points restants de `docs/premier-demarrage.md` : son, second écran, recherche
   par nom, mise en veille, première `apt full-upgrade` (puis `sudo ls /boot/efi/EFI/BOOT`), essai sur un
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

- Pont SSK 1 To `090c:2320` (Silicon Motion SM2320, contrôleur de SSD USB natif) en UAS sur le HP ProBook : aucune réinitialisation constatée à l'usage (2026-11-08). En
  cas de déconnexions (`uas_eh` dans le journal du noyau) : quirk `usb-storage.quirks=090c:2320:u`
  (perd UAS et TRIM).
- Pont VIA Labs `2109:0715` (clé SSK 128 Go, 2026-11-08 ; `lsusb` : « VL817 SATA Adaptor », probablement
  un VL715 vers SSD SATA) : `usb-storage` (UAS ignoré par le noyau
  pour ce pont), pas de TRIM (« Illegal Request »), 10 Gbit/s négociés ; démarrage et contrôles
  conformes.
