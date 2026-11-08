# Diagnostics : la clé avant le déploiement, le système après

Deux outils, deux moments (D-048), et un rapport qui les rassemble (D-049). Conception :
`docs/developpement/conception-0.2.md`.

| | `make diag-cle` | `nomade-diag` |
|---|---|---|
| Où | sur l'hôte, depuis le dépôt | sur la clé déployée (menu « Diagnostic de la clé », ou terminal) |
| Quoi | la clé seule : puce, pont, liaison, TRIM, SMART, lectures ; sur demande capacité réelle et écritures | le PC, le démarrage, la mémoire, les erreurs, et la clé sur ce PC |
| Écrit | rien, sauf `COMPLET=1`, qui **efface la clé** | l'archive ; avec `--mesures`, un fichier d'essai sans nom (≤ 1 Gio) |
| Rapport | `diagnostics/archives/` | `NOMADE-DATA/nomade-diag/` (sinon `~/nomade-diag/`) |

Les rapports sont **anonymisés** : numéros de série remplacés par une empreinte salée, ni adresse MAC,
ni IP, ni nom de réseau, ni nom de personne. Une archive dont le contrôle final trouve encore un
identifiant n'est pas écrite.

## Avant le déploiement : `make diag-cle`

```bash
ls -l /dev/disk/by-id/ | grep usb                           # trouver la clé
make diag-cle KEY=/dev/disk/by-id/usb-…                     # identification seule, sans root (2 s)
sudo make diag-cle KEY=/dev/disk/by-id/usb-…                # + SMART et lectures directes (≈ 30 s), rien n'est écrit
sudo make diag-cle KEY=/dev/disk/by-id/usb-… COMPLET=1      # analyse complète : EFFACE la clé (≈ 3 à 5 min)
sudo make diag-cle KEY=… COMPLET=1 DUREE=3                  # écriture longue de 3 min au lieu d'1
```

- **Lecture seule** (par défaut) : identification (VID:PID, table des puces de Fabrique-Clé, pilote
  `uas` ou `usb-storage`, liaison négociée, TRIM annoncé, rotative déclarée), SMART si `smartctl` est
  installé et que le pont le relaie, puis lectures directes : séquentielle, aléatoire de 4 Kio une à la
  fois et 8 à la fois, 8 s chacune. La clé peut être montée, ou déjà une clé nomade : elle n'est pas
  modifiée.
- **Analyse complète** (`COMPLET=1`) : même confirmation que `deploy` (numéro de série à taper).
  Capacité réelle (marqueurs sur toute la surface : une contrefaçon replie ses adresses), essai de TRIM
  réel, écritures aléatoires et synchronisées, écriture longue (`DUREE` minutes, 1 par défaut) avec le
  moment où le débit chute (fin du cache rapide), puis remise à vide. Elle écrit jusqu'à `DUREE` × débit
  (≈ 30 Go en 1 min sur un SSD rapide) : sans importance pour un SSD, inutile à répéter sur une clé
  ordinaire.
- **Verdict** : catégorie A à D (seuils de Fabrique-Clé : écriture aléatoire de 4 Kio), estimée en
  lecture seule, mesurée après l'analyse complète, et alertes (« ne pas déployer », « change de port »…).
- `sudo make deploy KEY=…` rappelle le verdict du dernier `diag-cle` de la même clé.

## Après le déploiement : `nomade-diag`

Sur la clé, menu des applications → **Diagnostic de la clé** (un terminal s'ouvre, demande le mot de
passe et reste ouvert à la fin), ou dans un terminal :

```bash
nomade-diag                  # ≈ 1 min : PC, Secure Boot, affichage, périphériques, démarrage, mémoire, erreurs
nomade-diag --mesures        # + lectures directes, écritures plafonnées à 1 Gio, chiffrement AES
nomade-diag --brut           # sans anonymisation, pour soi (refusé par make diag-rapport)
```

Le rapport (`nomade-diag-<date>-<modèle>.tar.zst`) va sur `NOMADE-DATA`, lisible depuis n'importe quel
PC. Il contient `resume.json`, `rapport.txt` (à lire), les sorties des commandes et le journal du noyau
nettoyés. Les points à retenir s'affichent à la fin : par exemple l'absence de « Microsoft Corporation
UEFI CA 2011 » dans le firmware (Secure Boot à régler), un rendu graphique logiciel, une liaison en
USB 2, des réinitialisations USB.

Sur une clé déployée avant la 0.2 (sans l'outil), depuis un clone du dépôt :
`config/rootfs/usr/local/bin/nomade-diag`.

## Rassembler : `make diag-rapport`

```bash
make diag-rapport SRC=/media/$USER/NOMADE-DATA/nomade-diag   # clé branchée sur l'hôte
make diag-rapport                                            # seulement diagnostics/archives/
```

Les archives sont copiées dans `diagnostics/archives/` (hors de git), leur `resume.json` contrôlé puis
rangé dans `diagnostics/resumes/` (versionné), et `docs/terrain.md` régénéré : clés, PC, couples PC × clé.

## `resume.json` : stabilité du schéma

`schema` (entier, 1 aujourd'hui) et `type` (`cle` ou `systeme`). Dans un même numéro, des champs
s'ajoutent ; aucun n'est renommé, retiré, ni ne change de sens ou d'unité (l'unité est dans le nom :
`_s`, `_mib`, `_gio`, `_mbps`, `_us`, `_mo_s`). `null` : non relevé. Une section en échec est notée
dans `non_lu`. Les ébauches commentées sont dans la note de conception, § 4.4.

## Empreintes

HMAC-SHA-256 tronqué à 16 caractères, avec le **sel de l'hôte** (`diagnostics/.sel`, hors de git,
tiré au premier diagnostic). `deploy.sh` copie ce sel sur la clé (`/var/lib/nomade/diag-sel`, racine
chiffrée) et inscrit l'empreinte de la clé dans `/etc/nomade/deploy-info` : la même clé et le même PC
gardent la même empreinte d'un diagnostic à l'autre, d'une clé de l'hôte à l'autre. Sans le sel, un
numéro de série ne se retrouve pas à partir de son empreinte.
