# Données de terrain

Généré par `make diag-rapport` à partir de `diagnostics/resumes/` (D-049) : **ne pas modifier à la main**. Un diagnostic par clé, par PC et par couple PC × clé : le plus récent. Diagnostics avant déploiement : `make diag-cle` ; sur la clé déployée : `nomade-diag`.

## Clés (`diag-cle`, avant déploiement)

| Date | Clé | Puce | Rôle | Pilote | Mbit/s | TRIM annoncé / réel | Gio | Lecture Mo/s | 4K IOPS | Gain ×8 | Écriture 4K Mo/s (1 / 8) | Cache SLC Gio | SMART écrit Gio | Catégorie | Déployable | Mode |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-08 | eab8a353 | 2109:0715 VIA Labs VL715 (probablement) | pont | usb-storage | 10000 | non / non | 119.2 | 351.7 | 4815 | 1.06 | 14.3 / 14.17 | 6.21 | — | C (mesuree) | oui | complet |

## PC (`nomade-diag`)

| Date | PC | Modèle | Firmware | RAM Mio | Secure Boot | MS UEFI CA 2011 | MS UEFI CA 2023 | GPU (pilote) | Rendu | Wi-Fi | Démarrage s (fw + chargeur + noyau + espace) | Alertes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-08 | 2396366b | HP ProBook 450 15.6 inch G9 Notebook PC | U72 Ver. 01.17.00 (11/06/2025) | 15622 | oui | oui | oui | Intel Corporation Alder Lake-UP3 GT2 [UHD Graphics] (i915) | matériel | rtw89_8852be ok | 15.2 + 6.7 + 14.5 + 11.9 | 0 |

## Couples PC × clé (`nomade-diag`)

| Date | PC | Clé | Empreinte | Pilote | Mbit/s | Réinit. USB | Lecture Mo/s | 4K IOPS (1 / 8) | Écriture Mo/s | AES Mio/s | Démarrage s | Version |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-08 | HP ProBook 450 15.6 inch G9 Notebook PC | 2109:0715 VIA Labs VL715 (probablement) | eab8a353 | usb-storage | 10000 | 0 | — | — / — | — | — | 48.4 | 0.2.0-alpha |
