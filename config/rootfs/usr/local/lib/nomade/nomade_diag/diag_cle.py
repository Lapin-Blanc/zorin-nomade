"""diag-cle : diagnostic d'une clé avant le déploiement, depuis l'hôte (D-048).

Lancé par scripts/diag-cle.sh, qui a passé les garde-fous. Modes :
- identification : sysfs, udev, hwdb, sans root ;
- lecture (défaut avec root) : + SMART et lectures directes ; rien n'est écrit sur la clé ;
- complet : + analyse complète, qui EFFACE la clé (analyse.py).
"""

import argparse
import os
import sys

from . import SCHEMA, analyse as A, archive, materiel, mesures as M, verdict as V
from .anonymat import Anonymiseur, lire_ou_creer_sel
from .commun import arrondi, est_root, horodatage, log, maintenant, sortie


def bloc_aleatoire(r):
    if not r:
        return None
    return {k: r.get(k) for k in ("en_parallele", "operations", "duree_s", "iops", "mo_s", "mediane_us",
                                  "p90_us", "p99_us", "max_us", "histogramme", "part_vide") if k in r}


def resume_lecture(lec):
    if not lec:
        return None
    s = lec["sequentielle"]
    return {"directes": lec["directes"],
            "sequentielle": {"mo_s": s["mo_s"], "duree_s": s["duree_s"], "part_vide": s["part_vide"]},
            "aleatoire_1": bloc_aleatoire(lec["aleatoire_1"]),
            "aleatoire_8": bloc_aleatoire(lec["aleatoire_8"]),
            "gain_parallele": lec["gain_parallele"]}


def resume_analyse(an):
    if not an:
        return None
    cap, lo = an["capacite"], an["ecriture_longue"]
    return {"directes": an["directes"],
            "capacite": {"marqueurs": cap["marqueurs"], "corrects": cap["corrects"],
                         "fiable_gio": arrondi(cap["fiable_octets"] / 2 ** 30, 2),
                         "repliement": cap["repliement"], "erreurs": cap["erreurs"], "conforme": cap["conforme"]},
            "trim_reel": an["trim_reel"], "zeros_apres_trim": an["zeros_apres_trim"],
            "ecriture_4k_1": bloc_aleatoire(an["ecriture_1"]),
            "ecriture_4k_8": bloc_aleatoire(an["ecriture_8"]),
            "ecriture_synchro": bloc_aleatoire(an["ecriture_synchro"]),
            "ecriture_longue": {"ecrit_gio": arrondi(lo["octets"] / 2 ** 30, 2), "duree_s": lo["duree_s"],
                                "mo_s": lo["mo_s"], "debit_debut_mo_s": lo["debit_debut_mo_s"],
                                "debit_fin_mo_s": lo["debit_fin_mo_s"],
                                "chute_apres_gio": arrondi(lo["chute_apres_octets"] / 2 ** 30, 2)
                                if lo["chute_apres_octets"] is not None else None,
                                "points": lo["points"]},
            "lecture_donnees": bloc_aleatoire(an["lecture_donnees"]),
            "remise_a_vide": an["remise_a_vide"]}


def bloc_cle(ident, empreinte, parts, smart):
    idf = ident.get("identification")
    return {
        "empreinte": empreinte,
        "vid_pid": "%04x:%04x" % (ident["vid"], ident["pid"]) if ident.get("vid") is not None else None,
        "identification": {"role": idf["role"], "nom": idf["nom"], "precision": idf["precision"]} if idf else None,
        "hwdb": {"fabricant": ident.get("hwdb_fabricant"), "produit": ident.get("hwdb_produit")},
        "descripteur": {"fabricant": ident.get("fabricant_usb"), "produit": ident.get("produit_usb"),
                        "modele_declare": ident.get("modele_declare")},
        "usb": {"version": ident.get("version_usb"), "vitesse_mbps": ident.get("vitesse_mbps"),
                "pilote": ident.get("pilote"), "bridee_usb2": ident.get("bridee_usb2"),
                "concentrateur": ident.get("concentrateur"), "quirk_usb_storage": ident.get("quirk_usb_storage")},
        "capacite_annoncee_gio": arrondi((ident.get("capacite_octets") or 0) / 2 ** 30, 1)
        if ident.get("capacite_octets") else None,
        "secteur_logique": ident.get("secteur_logique"), "secteur_physique": ident.get("secteur_physique"),
        "transfert_max_kio": ident.get("transfert_max_kio"),
        "trim_declare": (ident["discard_max_octets"] > 0) if ident.get("discard_max_octets") is not None else None,
        "provisioning_mode": ident.get("provisioning_mode"), "file_commandes": ident.get("file_commandes"),
        "rotatif_declare": ident.get("rotatif_declare"), "ordonnanceur": ident.get("ordonnanceur"),
        "partitions": parts, "smart": smart,
    }


def fr(x):
    """Valeur lisible en français dans rapport.txt."""
    return {True: "oui", False: "non", None: "?"}.get(x, x) if isinstance(x, (bool, type(None))) else x


def texte_rapport(res):
    c, v = res["cle"], res["verdict"]
    L = ["Diagnostic de clé zorin-nomade (%s, %s)" % (res["outil"]["version"], res["date"]),
         "Mode : %s" % res["options"]["mode"], ""]
    idf = c.get("identification") or {}
    L.append("Clé : %s — %s" % (c.get("vid_pid") or "VID:PID inconnu",
                                idf.get("nom") or c["hwdb"].get("produit") or "puce inconnue"))
    if idf:
        L.append("  rôle (table) : %s (%s)" % (idf["role"], idf["precision"]))
    u = c["usb"]
    L.append("  USB %s, liaison %s Mbit/s, pilote %s%s" % (u.get("version") or "?", u.get("vitesse_mbps") or "?",
                                                         u.get("pilote") or "?",
                                                         ", via un concentrateur" if u.get("concentrateur") else ""))
    L.append("  capacité annoncée %s Gio ; TRIM annoncé : %s ; rotative déclarée : %s ; file de commandes : %s"
             % (fr(c.get("capacite_annoncee_gio")), fr(c.get("trim_declare")), fr(c.get("rotatif_declare")),
                fr(c.get("file_commandes"))))
    if c.get("smart"):
        s = c["smart"]
        L.append("  SMART (%s) : sain %s, %s h, %s Gio écrits, usure %s %%"
                 % (s.get("type"), fr(s.get("sain")), fr(s.get("heures")), fr(s.get("ecrit_gio")), fr(s.get("usure_pct"))))
    else:
        L.append("  SMART : non lu")
    lec = res.get("lecture")
    if lec:
        a1, a8 = lec["aleatoire_1"], lec["aleatoire_8"]
        L += ["", "Lecture (rien n'a été écrit) :",
              "  séquentielle %s Mo/s" % lec["sequentielle"]["mo_s"],
              "  4 Kio une à la fois : %s IOPS, médiane %s µs, 99 %% %s µs" % (a1["iops"], a1["mediane_us"], a1["p99_us"]),
              "  4 Kio 8 à la fois : %s IOPS (gain ×%s)" % (a8["iops"], lec["gain_parallele"])]
    an = res.get("analyse")
    if an:
        cap, lo = an["capacite"], an["ecriture_longue"]
        L += ["", "Analyse complète (la clé a été effacée) :",
              "  capacité : %s/%s marqueurs, %s Gio fiables%s" % (cap["corrects"], cap["marqueurs"], cap["fiable_gio"],
                                                                 ", REPLIEMENT" if cap["repliement"] else ""),
              "  TRIM réel : %s" % fr(an["trim_reel"]),
              "  écriture 4 Kio : %s Mo/s (1), %s Mo/s (8) ; synchronisée : médiane %s µs"
              % (an["ecriture_4k_1"]["mo_s"], an["ecriture_4k_8"]["mo_s"], an["ecriture_synchro"]["mediane_us"]),
              "  écriture longue : %s Gio en %s s, %s Mo/s (début %s, fin %s)%s"
              % (lo["ecrit_gio"], lo["duree_s"], lo["mo_s"], lo["debit_debut_mo_s"], lo["debit_fin_mo_s"],
                 ", chute du cache après %s Gio" % lo["chute_apres_gio"] if lo["chute_apres_gio"] is not None
                 else ", cache non épuisé pendant la mesure"),
              "  remise à vide : %s" % an["remise_a_vide"]]
    L += ["", "Verdict : %s" % v["texte"], "Déployable : %s" % ("oui" if v["deployable"] else "NON")]
    for x in v["alertes"]:
        L.append("  [%s] %s" % (x["niveau"], x["texte"]))
    return "\n".join(L) + "\n"


def main(argv):
    p = argparse.ArgumentParser(prog="diag-cle")
    p.add_argument("--disque", required=True)
    p.add_argument("--mode", choices=("identification", "lecture", "complet"), default="lecture")
    p.add_argument("--duree-min", type=float, default=1.0)
    p.add_argument("--sel", required=True)
    p.add_argument("--sortie", required=True)
    p.add_argument("--version", default="?")
    p.add_argument("--brut", action="store_true")
    p.add_argument("--taille-min-gio", type=int, default=31)
    p.add_argument("--cache", action="append", default=[], help="valeur à masquer (chemin by-id…)")
    p.add_argument("--uid", type=int)
    p.add_argument("--gid", type=int)
    p.add_argument("--utilisateur")
    a = p.parse_args(argv)
    if a.mode != "identification" and not est_root():
        log("sans root : identification seule (sudo make diag-cle pour les lectures)")
        a.mode = "identification"

    sel = lire_ou_creer_sel(a.sel, a.uid, a.gid)
    anon = Anonymiseur(sel, actif=not a.brut, utilisateur=a.utilisateur)
    log("identification de %s" % a.disque)
    ident = materiel.identifier(a.disque)
    for genre, v in ident.pop("_secrets"):
        anon.secret(genre, v)
    for v in a.cache:
        anon.secret("lien", v)
        anon.secret("lien", os.path.basename(v))
    empreinte = materiel.empreinte_cle(anon, a.disque, ident)      # D-049
    parts = materiel.partitions(a.disque)

    smart, smart_json = None, None
    if est_root():
        smart, smart_json = materiel.smart(a.disque, ident)
        for genre, v in materiel.secrets_smart(smart_json):
            anon.secret(genre, v)
        if smart is None:
            log("SMART : non lu (smartctl absent ou non relayé par le pont)")

    lec = None
    if a.mode in ("lecture", "complet"):
        log("lectures directes (≈ %d s), rien n'est écrit" % (3 * M.DUREE_LECTURE_S))
        lec = M.lecture(a.disque)
    an = None
    if a.mode == "complet":
        log("analyse complète : la clé est EFFACÉE")
        an = A.analyser(a.disque, duree_longue_s=int(a.duree_min * 60))

    res = {"schema": SCHEMA, "type": "cle", "outil": {"nom": "diag-cle", "version": a.version},
           "date": maintenant(), "anonymise": not a.brut,
           "options": {"mode": a.mode, "duree_ecriture_min": a.duree_min if a.mode == "complet" else None,
                       "root": est_root()},
           "cle": bloc_cle(ident, empreinte, parts, smart),
           "lecture": resume_lecture(lec), "analyse": resume_analyse(an)}
    res["verdict"] = V.verdict(ident, lec, an, smart, a.taille_min_gio)
    rapport = texte_rapport(res)

    fichiers = {"resume.json": archive.json_texte(res), "rapport.txt": rapport}
    if lec:
        fichiers["mesures/lecture.json"] = archive.json_texte(lec)
    if an:
        fichiers["mesures/analyse.json"] = archive.json_texte(an)
    brut = {
        "brut/udevadm.txt": sortie(["udevadm", "info", "--query=all", "--name=" + a.disque]),
        "brut/lsusb-t.txt": sortie(["lsusb", "-t"]),
        "brut/lsblk.txt": sortie(["lsblk", "-b", "-o", "NAME,SIZE,TYPE,FSTYPE,PARTTYPE,TRAN,ROTA,DISC-MAX,SCHED",
                                  a.disque]),
    }
    if ident.get("vid") is not None:
        brut["brut/lsusb-v.txt"] = sortie(["lsusb", "-v", "-d", "%04x:%04x" % (ident["vid"], ident["pid"])])
    if smart_json:
        brut["brut/smart.json"] = archive.json_texte(smart_json)
    for k, v in brut.items():
        fichiers[k] = anon.nettoyer(v)
    probleme = []
    for nom, texte in fichiers.items():
        probleme += anon.trouvailles(nom, texte, motifs=nom.startswith("brut/"))
    if probleme:
        for x in probleme:
            log("ANONYMISATION : " + x)
        log("archive non écrite : identifiant résiduel (voir ci-dessus)")
        return 3

    nom = "diag-cle-%s-%s-%s%s" % (horodatage(), (res["cle"]["vid_pid"] or "inconnu").replace(":", "-"),
                                   empreinte[:8], "-brut" if a.brut else "")
    chemin = archive.ecrire(a.sortie, nom, fichiers, a.uid, a.gid)
    sys.stdout.write(rapport)
    sys.stdout.write("\nArchive : %s\n" % chemin)
    return 0
