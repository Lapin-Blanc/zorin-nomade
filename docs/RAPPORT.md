# Rapport du run autonome (phases 2 à 5)

Rédigé le 2026-11-08 pour Fabien. Le détail chronologique est dans `docs/JOURNAL.md`, les choix
dans `DECISIONS.md` (D-013 à D-038), les constats sur l'ISO dans `docs/iso-notes.md`.

## 1. En bref

- **L'image est complète** : Zorin OS 18.1 Core installé (sans casper ni installateur), à jour
  (noyau 7.0.0-42), en français de Belgique, réglée pour une clé USB (zram, `/tmp` en RAM, écritures
  regroupées, journal plafonné, psd pour Brave, indexation du contenu coupée, services inutiles
  désactivés), démarrable par le chemin amovible UEFI **avec et sans Secure Boot**.
- **`make test`** : `RESULT=PASS` avec Secure Boot activé et désactivé, **103 contrôles** chacun.
- **Le déploiement est écrit et testé** : `sudo make deploy KEY=…` écrit l'image, agrandit la racine,
  la chiffre en LUKS2 (clé de volume tirée sur place), règle l'initramfs, GRUB et la règle udev du
  pont. `make deploy-test` (deux déploiements de suite sur un fichier de 64 Gio, puis démarrage avec
  la phrase tapée au clavier AZERTY virtuel) : `RESULT=PASS`, **118 contrôles**, Secure Boot activé
  et désactivé.
- **La CI est prête** (lint + garde-fous à chaque push ; construction + tests QEMU sur les
  changements) mais **rien n'est poussé** : il n'y a pas encore de dépôt GitHub.
- **Reproductibilité** (E-38) : `make builder-destroy && make all` depuis un clone propre aboutit
  (19 min 26 s, `RESULT=PASS` avec et sans Secure Boot). Ce test a révélé un défaut, corrigé : chemin
  des sockets QMP trop long quand le dépôt est dans un dossier profond.
- **Rien n'a été écrit sur un vrai périphérique**, rien n'a été lancé en root sur l'hôte.

## 2. Ce qui a été fait

| Phase | Contenu | Commit |
|---|---|---|
| 2 | `/tmp` en tmpfs, profil dconf `user` + base `local`, psd (définition Brave), services E-40 désactivés, paquets de langue vérifiés, manifeste dans `/etc/nomade/`, autotest étendu de 48 à 103 contrôles | `dc9da80` |
| 3 | `scripts/deploy.sh`, `scripts/deploy-test.sh`, `test-image.sh --encrypted`, contrôles « clé déployée » dans l'autotest | `97c480c` |
| 4 | `.github/workflows/image.yml`, `lint.yml` → `make ci`, `scripts/test-guards.sh` (16 refus attendus des garde-fous), README | `9bd403d` |
| 5 | reproductibilité depuis un clone propre (correctif des sockets QMP `6b00b2d`), ce rapport | (dernier commit) |

### Le déploiement, étape par étape (`scripts/deploy.sh`)

1. Garde-fous : `assert_real_usb_target` (chemin `by-id/usb-*`, disque entier, USB, non monté,
   pas le disque système, **saisie du numéro de série**) ; en test, `assert_test_target`.
2. Phrase LUKS et mot de passe saisis deux fois, sans écho, ASCII uniquement ; ils ne passent que
   par des tubes (jamais en argument, fichier ou journal).
3. VID:PID du pont lu dans sysfs ; essai de TRIM sur le premier Mio (avec `provisioning_mode=unmap`
   le temps de l'essai si le pont ne l'annonce pas).
4. Clé effacée (TRIM complet si l'essai a réussi, sinon `wipefs`), image écrite par `bmaptool`.
5. Table GPT : en-tête de secours en fin de clé, p3 agrandie (moins `DEPLOY_DATA_GIB` ; partition
   exFAT `NOMADE-DATA` si demandée).
6. Racine : **recréée** chiffrée (D-035) — TRIM de p3, `luksFormat` LUKS2 (secteurs de 4 Kio),
   ouverture avec drapeaux persistants `allow-discards`, `no-read-workqueue`, `no-write-workqueue`,
   `mkfs.ext4` au même UUID, copie `rsync -aHAXS` depuis l'image. Seules les données utiles
   (≈ 6,5 Gio) sont écrites, au lieu de relire et réécrire toute la partition.
7. Chroot : `crypttab` (`luks,discard,initramfs`), mot de passe, règle udev
   `60-nomade-usb.rules`, `/etc/nomade/deploy-info`, `update-initramfs` (disposition `be` et
   `crypttab` vérifiées dans l'initrd), `update-grub`.
8. Contrôles : `e2fsck`, `fsck.vfat`, chemin amovible complet, puis checklist affichée.

Pendant un déploiement réel, GNOME ne monte pas les partitions de la clé (règle udev temporaire dans
`/run`, retirée à la fin) et tous les montages se font dans un espace de noms privé.

## 3. Résultats des tests

| Essai | Résultat | Contrôles | Durée |
|---|---|---|---|
| `make test`, Secure Boot activé | PASS | 103 | 84 s |
| `make test`, Secure Boot désactivé | PASS | 103 | 84 s |
| `make deploy-test RUNS=2`, Secure Boot activé | PASS | 118 | 105 s |
| `make deploy-test RUNS=2`, Secure Boot désactivé | PASS | 118 | 102 s |
| `make ci` (shellcheck + garde-fous) | ok | 16 refus | 2 s |

Ce que prouve le test chiffré : la question LUKS apparaît (« Please unlock disk nomade-root »,
indicateur **be**, capture `out/test/deploy-on/question.png`) ; la phrase contient « a », « z » et
« m » et le harnais tape les **touches d'un AZERTY** — elle est acceptée en 3 s, donc l'initramfs est
bien en disposition belge (E-30) ; GDM affiche ensuite le compte « Fabien ».

## 4. Déviations et décisions de ce run

| | Sujet | Effet |
|---|---|---|
| D-034 | `KEYMAP=y` sans effet sous Ubuntu : le crochet `console_setup` embarque toujours la disposition | contrôle sur le fichier réellement embarqué ; disposition prouvée par le test chiffré |
| D-035 | Racine chiffrée par **recréation** + `rsync`, pas par `cryptsetup reencrypt` en place | ≈ 7 Gio écrits au lieu de toute la partition lue et réécrite ; fichier de test creux |
| D-036 | Détails du déploiement : essai de TRIM, udisks ignoré, ASCII, PBKDF allégé **en test seulement** | — |
| D-037 | Question LUKS repérée par l'inactivité du disque (QMP), pas d'OCR ni de console série | rien n'est ajouté au système déployé |
| D-038 | `/tmp` : copie de `tmp.mount` dans `/etc` | méthode Ubuntu |

Aucune exigence de `SPEC.md` n'est abandonnée.

## 5. Durées et tailles

| | |
|---|---|
| Construction (`make image`, cache APT présent) | ≈ 10 min dans la VM + 1 min 40 de rapatriement |
| Construction depuis zéro (`make builder-destroy && make all`, clone propre) | **19 min 26 s** : VM neuve ≈ 1 min 30, build 13 min (1,7 Go de paquets retéléchargés), rapatriement 1 min 30, tests 3 min |
| Image | 27 650 Mio apparents, **6,8 Gio alloués** ; `.bmap` 1,1 Mo ; 1 838 paquets au manifeste |
| `make test` (deux essais) | ≈ 3 min |
| Déploiement (dans la VM, sur fichier) | ≈ 3 min ; sur la clé réelle, compter ≈ 10 min (USB 3) |
| `make deploy-test` complet | ≈ 15 min (dont ≈ 2 min d'envoi de l'image et 2 min de rapatriement) |
| Fichier déployé rapatrié | 64 Gio apparents, 7,9 Gio alloués |

## 6. Limites connues

- **Pas encore essayé sur vrai matériel** : UAS et TRIM à travers le pont SSK `090c:2320`, Wi-Fi,
  son, GPU NVIDIA (nouveau), firmwares réels avec Secure Boot. En test, la clé est un `usb-storage`
  QEMU (protocole BOT, pas UAS, VID:PID `46f4:0001`).
- **psd** et la **recherche par nom** ne sont vérifiés que par la configuration (aucune session
  ouverte dans les tests). psd n'a rien à synchroniser avant le premier lancement de Brave : le profil
  passe en RAM à la session suivante.
- **Mises à jour de GRUB et de shim** : vérifiées par une réinstallation simulée au build (D-029,
  D-033), pas par une vraie mise à jour publiée.
- **Premier démarrage d'une grande clé** : ext4 initialise ses tables d'inodes en arrière-plan
  (`ext4lazyinit`) ; sur 1 To, quelques Gio écrits pendant les premières minutes. Normal, une seule
  fois.
- **Réserve root de 5 %** (défaut ext4) sur la racine agrandie : `sudo tune2fs -m 1 /dev/mapper/nomade-root`
  la réduit si tu le souhaites.
- **Phrase LUKS en ASCII uniquement** (refus des caractères accentués à la saisie).
- Le déploiement lit la racine dans l'image (`out/latest.img`) : il faut l'image sur la machine qui
  déploie (c'est le cas sur ton hôte).
- La VM de build a été détruite par le test de reproductibilité : le prochain `make image` la
  recrée (≈ 1 min 30) et retélécharge ≈ 1,7 Go de paquets (cache APT perdu avec la VM ; l'ISO reste
  dans `cache/`).
- Le groupe `sambashare` n'existe pas (Samba absent) : l'utilisateur n'y est pas.
- Le workflow `image` n'a pas encore tourné sur GitHub (`actionlint` absent de l'hôte : validé par
  chargement YAML et shellcheck des étapes).

## 7. Checklist du premier démarrage natif

À faire sur un vrai PC, idéalement **un PC avec Secure Boot actif et un PC sans**.

**Démarrage**
- [ ] Clé sur un port USB 3, menu de démarrage du firmware (F12, F9, F8, Échap selon le PC) →
      entrée USB/UEFI de la clé. Rien à ajouter dans le firmware.
- [ ] Menu GRUB visible 3 s (entrées « Zorin OS » et options avancées).
- [ ] Question LUKS : la phrase se tape en clavier belge ; l'indicateur affiche `be`.
- [ ] Écran de connexion, session GNOME ouverte avec ton mot de passe.
- [ ] `mokutil --sb-state` → l'état attendu selon le PC.
- [ ] Secure Boot activé et clé refusée : vérifier l'option du firmware qui autorise « Microsoft UEFI CA »
      (README § 5, PC « Secured-core »).
- [ ] Clé débranchée, le menu de démarrage du firmware **ne garde aucune entrée « ubuntu » ou
      « Zorin »** (la clé n'écrit jamais en NVRAM ; seule l'entrée USB générique du firmware
      apparaît quand la clé est branchée).

**Matériel**
- [ ] Wi-Fi (connexion à un réseau), son (haut-parleurs, prise casque), écran (résolution, second
      écran).
- [ ] `lsusb -t` → le pont de la clé utilise le pilote **`uas`** (`Driver=uas`).
- [ ] `journalctl -k | grep -i uas_eh` → **rien** (sinon : resets UAS du pont SSK, à me signaler ;
      contournement `usb-storage.quirks=090c:2320:u` sur la ligne du noyau).
- [ ] `cat /etc/nomade/deploy-info` → `DEPLOY_USB_ID=090c:2320` (ou le VID:PID réel du pont) et
      `DEPLOY_DISCARD=1` si le TRIM a été accepté.

**SSD et chiffrement**
- [ ] `lsblk --discard` → valeurs `DISC-GRAN`/`DISC-MAX` non nulles pour `sdX`, `sdX3` et
      `nomade-root`.
- [ ] `cat /sys/block/sdX/queue/rotational` → `0` ; `cat /sys/block/sdX/queue/scheduler` →
      `[mq-deadline]`.
- [ ] `sudo fstrim -v /` → une quantité « trimmed » (et `systemctl status fstrim.timer` actif).
- [ ] `sudo cryptsetup status nomade-root` → `flags: discards no_read_workqueue no_write_workqueue`.

**Réglages**
- [ ] `swapon` → seulement `/dev/zram0`, priorité 100 ; `findmnt /tmp` → `tmpfs`.
- [ ] Brave : le lancer une fois, se déconnecter puis se reconnecter, puis `psd p` → profil
      `Brave-Browser` synchronisé en RAM (« sync: yes »).
- [ ] Recherche par nom : touche Super, taper le nom d'un fichier de `~/Documents` → il apparaît.
- [ ] Logiciels (GNOME) : pas de téléchargement en arrière-plan ; les mises à jour de sécurité
      automatiques restent actives (`systemctl status unattended-upgrades`).
- [ ] `systemd-analyze` → durée de démarrage (pour comparer d'un PC à l'autre).
- [ ] Mise en veille : fermer le capot (ou attendre 15 min sur batterie), rouvrir, puis
      `journalctl -k -b | grep -iE 'uas|reset|I/O error'` → rien de neuf depuis la mise en veille.

**Première mise à jour**
- [ ] `sudo apt update && sudo apt full-upgrade` → puis `ls /boot/efi/EFI/BOOT` : `BOOTX64.EFI`,
      `grubx64.efi`, `mmx64.efi`, `grub.cfg`, et **ni `fbx64.efi` ni `BOOTX64.CSV`** ; redémarrer.

## 8. Ce qui reste à faire de ton côté (synthèse)

1. **Déployer la clé** : `sudo make deploy KEY=/dev/disk/by-id/usb-…` (README § 5), puis la
   checklist du § 7 sur au moins deux PC (Secure Boot actif et inactif).
2. **Activer la CI** (facultatif) : créer le dépôt GitHub et pousser — marche à suivre dans
   `docs/A-FAIRE-FABIEN.md` ; vérifier que le workflow `image` est vert.
3. **Décider du sort de `.claude/settings copy.json`** : sa suppression est en attente dans l'arbre
   de travail (je ne l'ai pas committée) ; les règles `deny` restent inactives (D-019).
4. Me signaler tout écart de la checklist (surtout `uas_eh`, Wi-Fi, TRIM) : chaque correction se
   fait dans `config/` ou les scripts, avec une ligne d'autotest.
