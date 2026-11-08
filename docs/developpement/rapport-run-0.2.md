# Rapport du run autonome de la 0.2 (2026-11-08)

Branche `retours-terrain`. Plan : `PLAN.md` (étapes R1 à R7), conception :
`docs/developpement/conception-0.2.md`, décisions D-046 à D-050.

## Ce qui est fait

| Étape | Contenu | Validation |
|---|---|---|
| R1 `NOMADE-DATA` | 10 % de la clé, plancher 8 Gio, aucune si la racine < 40 Gio ; `fstab` par UUID sur `/media/NOMADE-DATA`, `uid` de l'utilisateur, `nofail` ; `exfatprogs` dans l'image | `make ci` (10 essais de `data_gib`) ; `make all` PASS ; `make deploy-test RUNS=2` PASS, 7 contrôles E-44 |
| R2 module et `diag-cle` en lecture seule | module Python `nomade_diag/` (identification, mesures, anonymisation, archive, verdict) ; `assert_usb_disk` ; `make diag-cle` | `make ci` (tests unitaires, refus des gardes) ; `make diag-cle-test` : fichier inchangé au SHA-256 près |
| R3 `diag-cle COMPLET=1` | capacité réelle, TRIM réel, écritures aléatoires et synchronisées, écriture longue (`DUREE=1`), remise à vide ; verdict A–D | `make diag-cle-test` : contrefaçon device-mapper détectée, « ne pas déployer » |
| R4 `nomade-diag` | collecte (PC, Secure Boot, affichage, périphériques, clé, démarrage, mémoire, écritures, erreurs), anonymisation, lanceur du menu, `selftest.sh --materiel` | autotest QEMU E-46 et E-47 : archive produite, aucune valeur repère (série du disque simulé, MAC, `machine-id`, utilisateur) |
| R5 `--mesures` | lectures directes, écritures `O_TMPFILE` plafonnées (1 Gio), AES | autotest (`--mesures --ecriture-max 64`) ; essai sur l'hôte (61 Mio écrits pour 64) |
| R6 rapport et liens | `make diag-rapport`, `diagnostics/`, `docs/terrain.md` ; `deploy.sh` : empreinte, sel copié, verdict du dernier `diag-cle` ; `make doctor` | tests unitaires ; `make deploy-test RUNS=2` PASS ; empreinte stable d'un démarrage à l'autre |

Image finale `zorin-nomade-20261108-1920` : `make test` PASS (Secure Boot activé et désactivé, 114 contrôles), `make deploy-test`
PASS (136 contrôles, dont E-44, E-46, E-47), `make ci` et `make diag-cle-test` PASS.

## Reste pour Fabien (étape 7 de la note)

1. `sudo apt install smartmontools` sur l'hôte (SMART dans `diag-cle`).
2. `sudo make diag-cle KEY=…` en lecture seule sur les deux clés (1 To et 128 Go).
3. Sur la 128 Go : `sudo make diag-cle KEY=… COMPLET=1`, puis redéploiement en 0.2 (`NOMADE-DATA` de
   11 Gio), `nomade-diag` sur quelques PC.
4. Sur la 1 To (pas de redéploiement) : `config/rootfs/usr/local/bin/nomade-diag` depuis le clone.
5. Étalonnage : l'onglet Diagnostic de Fabrique-Clé sur la même clé que `diag-cle`.
6. `make diag-rapport SRC=/media/$USER/NOMADE-DATA/nomade-diag`, puis relire `docs/terrain.md`.

## Points d'attention

- Les mesures dans la VM et dans QEMU n'ont pas de sens : seuls le déroulement et le format sont
  vérifiés. Le vrai matériel dira si les seuils A–D et la détection de la chute du cache tiennent.
- SMART à travers les ponts n'a pas pu être essayé (ni `smartctl` sur l'hôte, ni pont dans la VM).
- `selftest.sh --materiel` n'a tourné que dans QEMU (appelé par `nomade-diag` dans l'autotest) : sur
  du vrai matériel, quelques contrôles peuvent échouer pour de bonnes raisons ; `nomade-diag` les
  rapporte sans s'arrêter.
- La CI GitHub n'a pas été relancée depuis la branche (pas de push sans accord de Fabien).
