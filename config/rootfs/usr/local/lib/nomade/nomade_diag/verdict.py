"""Verdict sur une clé : catégorie A à D et alertes (seuils de Fabrique-Clé,
app/src/diagnostic/interpretation.rs, ``estimation``). Seuils indicatifs, à calibrer sur le terrain.

Catégories (écriture aléatoire de 4 Kio, la meilleure des deux mesures) :
  A  < 0,1 Mo/s   clé basique, inutilisable pour un système
  B  < 2 Mo/s     clé « rapide » grand public : le bureau peut se figer pendant les écritures
  B-C < 10 Mo/s   nettement meilleure qu'une clé ordinaire
  C  < 30 Mo/s    contrôleur de type SSD : un bon choix
  D  au-delà      performances de SSD
Sans analyse complète, la catégorie est estimée d'après les indices (pont ou SSD connu, UAS, TRIM,
gain des lectures parallèles).
"""

TEXTES = {
    "A": "Catégorie A : clé basique. Inutilisable pour un système.",
    "B": "Catégorie B : clé « rapide » grand public. Le système fonctionnera grâce aux réglages de "
         "l'image, mais le bureau pourra se figer pendant les écritures.",
    "B-C": "Entre les catégories B et C : nettement meilleure qu'une clé ordinaire.",
    "C": "Catégorie C : contrôleur de type SSD. Un bon choix pour un système.",
    "D": "Catégorie D : performances de SSD. Excellent pour un système.",
    "C-D?": "Plutôt catégorie C ou D : contrôleur de type SSD. Un bon choix pour un système.",
    "B-C?": "Entre B et C : la clé a l'UAS, mais pas tous les signes d'un contrôleur de SSD.",
    "A-B?": "Plutôt catégorie A ou B : clé ordinaire. Le système fonctionnera grâce aux réglages de "
            "l'image, mais restera lent en écriture.",
    "?": "Indéterminée : pas assez d'informations.",
    "contrefacon": "Clé contrefaite ou défectueuse : sa capacité réelle ne correspond pas à l'annonce. "
                   "À ne pas utiliser.",
}


def categorie_mesuree(ecriture_4k_mo_s):
    w = ecriture_4k_mo_s
    if w < 0.1:
        return "A"
    if w < 2:
        return "B"
    if w < 10:
        return "B-C"
    if w < 30:
        return "C"
    return "D"


def categorie_estimee(ident, lecture):
    pilote = (ident.get("pilote") or "").lower()
    uas, bot = pilote == "uas", pilote == "usb-storage"
    trim = (ident.get("discard_max_octets") or 0) > 0
    gain = (lecture or {}).get("gain_parallele")
    role = (ident.get("identification") or {}).get("role")
    if role in ("pont", "ssd") or (uas and trim and (gain is None or gain >= 1.8)):
        return "C-D?"
    if uas:
        return "B-C?"
    if bot or (gain is not None and gain < 1.2):
        return "A-B?"
    return "?"


def verdict(ident, lecture, analyse, smart, taille_min_gio):
    alertes = []

    def a(niveau, texte):
        alertes.append({"niveau": niveau, "texte": texte})

    if analyse:
        cap = analyse["capacite"]
        if not cap["conforme"]:
            cat, certitude = "contrefacon", "mesuree"
            a("bloquant", "Capacité réelle inférieure à l'annonce ou erreurs d'écriture (%s marqueurs sur %s "
              "relus, %.1f Gio fiables%s) : ne pas déployer."
              % (cap["corrects"], cap["marqueurs"], cap["fiable_octets"] / 2 ** 30,
                 ", adresses repliées" if cap["repliement"] else ""))
        else:
            w = max(analyse["ecriture_1"]["mo_s"], analyse["ecriture_8"]["mo_s"])
            cat, certitude = categorie_mesuree(w), "mesuree"
        if analyse.get("trim_reel") is False:
            a("info", "TRIM refusé à travers ce pont (%s) : le système fonctionnera sans TRIM."
              % (analyse.get("trim_cause") or "cause inconnue"))
    elif lecture:
        cat, certitude = categorie_estimee(ident, lecture), "estimee"
    else:
        cat, certitude = categorie_estimee(ident, None), "estimee"
    if cat == "?":
        certitude = "indeterminee"

    cap_gio = (ident.get("capacite_octets") or 0) / 2 ** 30
    if ident.get("capacite_octets") and cap_gio < taille_min_gio:
        a("bloquant", "Clé trop petite : %.1f Gio, il en faut au moins %d pour l'image." % (cap_gio, taille_min_gio))
    if ident.get("bridee_usb2"):
        a("attention", "Liaison en USB 2 alors que la clé sait faire de l'USB 3 : change de port, de câble "
          "ou retire la rallonge.")
    if ident.get("concentrateur"):
        a("info", "La clé passe par un concentrateur USB : branche-la directement sur le PC pour mesurer.")
    role = (ident.get("identification") or {}).get("role")
    if role == "suspect":
        a("attention", "Identifiant USB fantaisiste, typique des clés anonymes ou contrefaites : fais "
          "l'analyse complète avant de déployer.")
    if (ident.get("pilote") or "") == "usb-storage":
        a("info", "Protocole usb-storage (BOT) : une commande à la fois, pas de TRIM ; le système "
          "fonctionnera, plus lentement sous charge.")
    if ident.get("discard_max_octets") == 0 and not analyse:
        a("info", "TRIM non annoncé par le pont (deploy.sh fera l'essai).")
    if ident.get("rotatif_declare"):
        a("info", "La clé se déclare rotative : corrigé par la règle udev au déploiement.")
    if smart:
        if smart.get("sain") is False:
            a("bloquant", "SMART signale un défaut du SSD : ne pas déployer.")
        if (smart.get("usure_pct") or 0) >= 80:
            a("attention", "SSD usé à %s %% d'après SMART." % smart["usure_pct"])
    if lecture and not lecture.get("directes"):
        a("attention", "Lectures passées par le cache du système : mesures peu fiables.")
    texte = TEXTES[cat]
    if certitude == "estimee":
        texte += " Estimation à confirmer par l'analyse complète (COMPLET=1), qui mesure l'écriture."
    return {"categorie": None if cat == "?" else cat.rstrip("?"), "certitude": certitude, "texte": texte,
            "deployable": not any(x["niveau"] == "bloquant" for x in alertes), "alertes": alertes}
