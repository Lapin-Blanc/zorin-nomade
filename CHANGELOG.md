# Journal des versions

Changements visibles de zorin-nomade, par version. Numérotation `MAJEUR.MINEUR.CORRECTIF[-alpha|-beta]`
(`PROJECT_VERSION` dans `config/project.env`) ; procédure de publication dans
`docs/developpement/README.md`. Détail chronologique : `docs/JOURNAL.md` ; raisons : `DECISIONS.md`.

## Non publié

(rien pour l'instant)

## 0.1.0-alpha — 2026-11-08

Première version utilisable : construite et testée les 2026-11-07 et 08, déployée sur la clé SSK de
Fabien (1 To) et utilisée depuis le 2026-11-08, puis sur une clé SSK de 128 Go (pont VIA VL817).

### Système produit
- Zorin OS 18.1 Core installé à partir du squashfs de l'ISO officielle (SHA-256 vérifié), sans casper,
  installateur, snapd ni census ; `apt full-upgrade` au build (noyau 7.0) ; manifeste des paquets.
- Démarrage UEFI par le chemin amovible (shim et GRUB signés), avec et sans Secure Boot, sans aucune
  écriture NVRAM, y compris aux mises à jour de GRUB et de shim (enveloppe `grub-install`, crochet APT).
- `fr_BE`, clavier belge jusque dans l'initramfs, fuseau de Bruxelles, horloge matérielle en heure locale.
- Réglages pour clé USB : zram (50 % de la RAM, zstd), `/tmp` en tmpfs, écritures regroupées
  (`dirty_*`, `commit=60`), journal plafonné à 200 Mo, `fstrim.timer`, dpkg sans `fsync`, psd pour Brave
  (`/run/user` à 25 % de la RAM), indexation du contenu coupée, services inutiles désactivés.
- Aucune écriture dans le firmware du PC hôte : `secureboot-db`, `fwupd` et `fwupd-refresh.timer`
  masqués (E-43).
- Version de l'outil inscrite dans `/etc/nomade/build-info` (`NOMADE_VERSION`).

### Construction et tests
- `make image` dans une VM de build jetable, sans root sur la machine ; `make test` dans QEMU (clé simulée
  en USB, Secure Boot activé puis désactivé, autotest embarqué de 108 contrôles).
- `make deploy-test` : déploiement chiffré complet sur fichier, rejoué deux fois, puis démarrage avec
  la phrase tapée au clavier virtuel.
- CI GitHub : lint à chaque push ; construction et `make test` sur les changements.
- `make help` affiche la version.

### Déploiement
- `sudo make deploy KEY=/dev/disk/by-id/usb-…` : garde-fous (disque USB entier, numéro de série à
  taper), image écrite par `bmaptool`, racine agrandie puis recréée en LUKS2 (clé de volume tirée sur la
  clé, drapeaux de performance persistants), partition exFAT facultative, règle udev du pont USB,
  initramfs et GRUB régénérés, contrôles finaux ; `DEPLOY_VERSION` dans `/etc/nomade/deploy-info`.

### Corrigé après le premier déploiement réel (2026-11-08)
- L'essai de TRIM échouait sur toute clé déjà partitionnée (`blkdiscard` sans `-f` depuis un terminal) :
  `DEPLOY_DISCARD=0` à tort, pas de TRIM complet de la clé.
- Racine recréée à 64 Kio par inode au lieu de 16 Kio : ≈ 12 Gio d'écritures en moins au premier
  démarrage d'une clé de 1 To.
- CI : accès à KVM rétabli après la construction.
- `deploy.sh` relève le pilote du pont USB (`DEPLOY_USB_DRIVER`) et adapte le récapitulatif final
  (pilote attendu, TRIM ou non) ; essayé sur un second pont, VIA VL817 (`usb-storage`, sans TRIM).

### Dépôt
- Le dépôt devient l'outil : `README.md` en mode d'emploi, checklist `docs/premier-demarrage.md`, traces
  de la construction dans `docs/developpement/`, ce journal des versions.
- Utilisable par simple clonage (D-045) : clonage en HTTPS, `config/local.env.example` pour régler
  compte, langue, clavier et fuseau sans toucher au dépôt ; `make doctor` n'échoue plus sur les
  garde-fous propres à Claude Code (avertissements, bloquants avec `STRICT=1`).
