"""diag-rapport : rassemble les diagnostics dans docs/terrain.md (D-049), sur l'hôte.

    make diag-rapport [SRC=/media/<utilisateur>/NOMADE-DATA/nomade-diag]

diagnostics/archives/ (ignoré par git) : archives de diag-cle et de nomade-diag ;
diagnostics/resumes/  (versionné)      : leur resume.json, après contrôle ;
docs/terrain.md       (versionné)      : tableaux comparatifs, régénérés à chaque fois.

Aussi, pour deploy.sh : ``empreinte-cle`` (empreinte d'une clé avec le sel de l'hôte) et
``verdict-cle`` (verdict du dernier diag-cle de cette clé).
"""

import argparse
import glob
import json
import os
import re
import shutil
import sys

from . import SCHEMA, archive, materiel
from .anonymat import RE_COURRIEL, RE_HOME, RE_MAC, Anonymiseur, lire_ou_creer_sel
from .commun import log

SCHEMAS_CONNUS = (1,)


def controle(resume, texte):
    """Raisons de refuser un résumé (liste vide : accepté)."""
    r = []
    if resume.get("schema") not in SCHEMAS_CONNUS:
        r.append("schéma inconnu : %s" % resume.get("schema"))
    if resume.get("type") not in ("cle", "systeme"):
        r.append("type inconnu : %s" % resume.get("type"))
    if resume.get("anonymise") is not True:
        r.append("archive non anonymisée (--brut)")
    if RE_MAC.search(texte) or RE_COURRIEL.search(texte) or RE_HOME.search(texte.replace("/home/utilisateur", "")):
        r.append("motif d'identifiant (MAC, courriel ou /home/<nom>)")
    return r


def importer(depot, src):
    arch = os.path.join(depot, "diagnostics", "archives")
    res = os.path.join(depot, "diagnostics", "resumes")
    os.makedirs(arch, exist_ok=True)
    os.makedirs(res, exist_ok=True)
    if src:
        for f in sorted(glob.glob(os.path.join(src, "*.tar.zst"))):
            cible = os.path.join(arch, os.path.basename(f))
            if not os.path.exists(cible):
                shutil.copy2(f, cible)
                log("copiée : %s" % os.path.basename(f))
    n = 0
    for f in sorted(glob.glob(os.path.join(arch, "*.tar.zst"))):
        nom = os.path.basename(f)[:-len(".tar.zst")]
        dest = os.path.join(res, nom + ".json")
        if os.path.exists(dest):
            continue
        try:
            r = archive.lire_resume(f)
        except Exception as e:
            log("illisible, ignorée : %s (%s)" % (nom, e))
            continue
        texte = archive.json_texte(r)
        refus = controle(r, texte)
        if refus:
            log("refusée : %s — %s" % (nom, " ; ".join(refus)))
            continue
        with open(dest, "w", encoding="utf-8") as fo:
            fo.write(texte)
        n += 1
    return n


def charger(depot):
    out = []
    for f in sorted(glob.glob(os.path.join(depot, "diagnostics", "resumes", "*.json"))):
        with open(f, encoding="utf-8") as fi:
            out.append(json.load(fi))
    return out


def v(x, *cles, defaut="—"):
    for k in cles:
        x = x.get(k) if isinstance(x, dict) else None
    if x is None or x == "" or x == []:
        return defaut
    if isinstance(x, bool):
        return "oui" if x else "non"
    return str(x).replace("|", "/").replace("\n", " ")


def plus_recents(resumes, cle):
    d = {}
    for r in sorted(resumes, key=lambda r: r.get("date") or ""):
        d[cle(r)] = r
    return [d[k] for k in sorted(d, key=lambda k: d[k].get("date") or "", reverse=True)]


def tableau(entetes, lignes):
    t = ["| " + " | ".join(entetes) + " |", "|" + "---|" * len(entetes)]
    t += ["| " + " | ".join(l_) + " |" for l_ in lignes]
    return "\n".join(t) if lignes else "_(aucun diagnostic pour l'instant)_"


def puce(c):
    idf = (c or {}).get("identification") or {}
    nom = idf.get("nom") or v(c, "hwdb", "produit")
    return "%s %s" % (v(c, "vid_pid"), nom.split(",")[0])


def generer(resumes):
    cles = plus_recents([r for r in resumes if r.get("type") == "cle"], lambda r: v(r, "cle", "empreinte"))
    systemes = [r for r in resumes if r.get("type") == "systeme"]
    pcs = plus_recents(systemes, lambda r: v(r, "pc", "empreinte"))
    couples = plus_recents(systemes, lambda r: (v(r, "pc", "empreinte"), v(r, "cle", "empreinte")))

    L = ["# Données de terrain", "",
         "Généré par `make diag-rapport` à partir de `diagnostics/resumes/` (D-049) : **ne pas modifier à la "
         "main**. Un diagnostic par clé, par PC et par couple PC × clé : le plus récent. "
         "Diagnostics avant déploiement : `make diag-cle` ; sur la clé déployée : `nomade-diag`.", ""]

    L += ["## Clés (`diag-cle`, avant déploiement)", ""]
    lignes = []
    for r in cles:
        c, lec, an, ve = r.get("cle") or {}, r.get("lecture") or {}, r.get("analyse") or {}, r.get("verdict") or {}
        lignes.append([v(r, "date")[:10], v(c, "empreinte")[:8], puce(c), v(c, "identification", "role"),
                       v(c, "usb", "pilote"), v(c, "usb", "vitesse_mbps"),
                       "%s / %s" % (v(c, "trim_declare"), v(an, "trim_reel")), v(c, "capacite_annoncee_gio"),
                       v(lec, "sequentielle", "mo_s"), v(lec, "aleatoire_1", "iops"), v(lec, "gain_parallele"),
                       "%s / %s" % (v(an, "ecriture_4k_1", "mo_s"), v(an, "ecriture_4k_8", "mo_s")),
                       v(an, "ecriture_longue", "chute_apres_gio"), v(c, "smart", "ecrit_gio"),
                       "%s (%s)" % (v(ve, "categorie"), v(ve, "certitude")), v(ve, "deployable"),
                       v(r, "options", "mode")])
    L.append(tableau(["Date", "Clé", "Puce", "Rôle", "Pilote", "Mbit/s", "TRIM annoncé / réel", "Gio",
                      "Lecture Mo/s", "4K IOPS", "Gain ×8", "Écriture 4K Mo/s (1 / 8)", "Cache SLC Gio",
                      "SMART écrit Gio", "Catégorie", "Déployable", "Mode"], lignes))
    alertes = [(r, x) for r in cles for x in (r.get("verdict") or {}).get("alertes", []) if x["niveau"] != "info"]
    if alertes:
        L += ["", "Alertes :"] + ["- `%s` %s : %s" % (v(r, "cle", "empreinte")[:8], x["niveau"], x["texte"])
                                 for r, x in alertes]

    L += ["", "## PC (`nomade-diag`)", ""]
    lignes = []
    for r in pcs:
        pc, sb, af, dem = r.get("pc") or {}, r.get("secure_boot") or {}, r.get("affichage") or {}, r.get("demarrage") or {}
        gpu = "; ".join("%s (%s)" % (g.get("nom"), g.get("pilote")) for g in af.get("gpu") or []) or "—"
        wifi = [x for x in (r.get("peripheriques") or {}).get("reseau", []) if x.get("type") == "wifi"]
        modele = v(pc, "modele")
        if not modele.startswith(v(pc, "fabricant")):
            modele = "%s %s" % (v(pc, "fabricant"), modele)
        lignes.append([v(r, "date")[:10], v(pc, "empreinte")[:8], modele,
                       "%s (%s)" % (v(pc, "firmware", "version"), v(pc, "firmware", "date")), v(pc, "ram_mib"),
                       v(sb, "actif"), v(sb, "ms_uefi_ca_2011"), v(sb, "ms_uefi_ca_2023"), gpu.replace("|", "/"),
                       "logiciel" if af.get("logiciel") else ("matériel" if af.get("logiciel") is False else "—"),
                       ", ".join("%s %s" % (x.get("pilote"), "ok" if x.get("fonctionne") else "—") for x in wifi) or "—",
                       "%s + %s + %s + %s" % (v(dem, "firmware_s"), v(dem, "chargeur_s"), v(dem, "noyau_s"),
                                              v(dem, "espace_utilisateur_s")),
                       str(len(r.get("alertes") or []))])
    L.append(tableau(["Date", "PC", "Modèle", "Firmware", "RAM Mio", "Secure Boot", "MS UEFI CA 2011",
                      "MS UEFI CA 2023", "GPU (pilote)", "Rendu", "Wi-Fi", "Démarrage s (fw + chargeur + noyau + espace)",
                      "Alertes"], lignes))

    L += ["", "## Couples PC × clé (`nomade-diag`)", ""]
    lignes = []
    for r in couples:
        c, me = r.get("cle") or {}, r.get("mesures") or {}
        lec, ec = me.get("lecture") or {}, me.get("ecriture") or {}
        lignes.append([v(r, "date")[:10], v(r, "pc", "modele"), puce(c), v(c, "empreinte")[:8],
                       v(c, "usb", "pilote"), v(c, "usb", "vitesse_mbps"), v(c, "reinitialisations_usb"),
                       v(lec, "sequentielle_mo_s"), "%s / %s" % (v(lec, "aleatoire_1", "iops"), v(lec, "aleatoire_8", "iops")),
                       v(ec, "ecriture_seq_mo_s"), v(me, "aes_xts", "chiffrement_mio_s"), v(r, "demarrage", "total_s"),
                       v(r, "systeme", "nomade_version")])
    L.append(tableau(["Date", "PC", "Clé", "Empreinte", "Pilote", "Mbit/s", "Réinit. USB", "Lecture Mo/s",
                      "4K IOPS (1 / 8)", "Écriture Mo/s", "AES Mio/s", "Démarrage s", "Version"], lignes))
    alertes = [(r, x) for r in pcs for x in r.get("alertes") or []]
    if alertes:
        L += ["", "Alertes des PC :"] + ["- `%s` %s : %s" % (v(r, "pc", "empreinte")[:8], v(r, "pc", "modele"), x)
                                         for r, x in alertes]
    return "\n".join(L) + "\n"


def main(argv):
    p = argparse.ArgumentParser(prog="diag-rapport")
    p.add_argument("--depot", required=True)
    p.add_argument("--src")
    a = p.parse_args(argv)
    n = importer(a.depot, a.src)
    resumes = charger(a.depot)
    texte = generer(resumes)
    with open(os.path.join(a.depot, "docs", "terrain.md"), "w", encoding="utf-8") as f:
        f.write(texte)
    log("%d nouveau(x) résumé(s), %d au total → docs/terrain.md" % (n, len(resumes)))
    return 0


def main_empreinte(argv):
    """Empreinte d'une clé avec le sel de l'hôte (crée le sel s'il manque)."""
    p = argparse.ArgumentParser(prog="empreinte-cle")
    p.add_argument("--disque", required=True)
    p.add_argument("--sel", required=True)
    p.add_argument("--uid", type=int)
    p.add_argument("--gid", type=int)
    a = p.parse_args(argv)
    anon = Anonymiseur(lire_ou_creer_sel(a.sel, a.uid, a.gid))
    print(materiel.empreinte_cle(anon, a.disque))
    return 0


def main_verdict(argv):
    """Verdict du dernier diag-cle d'une clé (d'après son empreinte), en une ligne."""
    p = argparse.ArgumentParser(prog="verdict-cle")
    p.add_argument("--depot", required=True)
    p.add_argument("--empreinte", required=True)
    a = p.parse_args(argv)
    if not re.fullmatch(r"[0-9a-f]{16}", a.empreinte):
        return 64
    trouves = []
    for f in glob.glob(os.path.join(a.depot, "diagnostics", "archives", "diag-cle-*-%s*.tar.zst" % a.empreinte[:8])):
        try:
            r = archive.lire_resume(f)
        except Exception:
            continue
        if (r.get("cle") or {}).get("empreinte") == a.empreinte:
            trouves.append(r)
    if not trouves:
        print("aucun")
        return 1
    r = max(trouves, key=lambda x: x.get("date") or "")
    ve = r.get("verdict") or {}
    print("%s (%s, mode %s) : %s Déployable : %s.%s" % (
        (r.get("date") or "?")[:16], r["outil"].get("version"), r["options"].get("mode"), ve.get("texte"),
        "oui" if ve.get("deployable") else "NON",
        "".join(" [%s] %s" % (x["niveau"], x["texte"]) for x in ve.get("alertes", []) if x["niveau"] != "info")))
    return 0 if ve.get("deployable") else 2


assert SCHEMA in SCHEMAS_CONNUS
