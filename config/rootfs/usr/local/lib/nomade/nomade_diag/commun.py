"""Utilitaires communs : lecture de fichiers, commandes bornées, journalisation, versions."""

import datetime
import os
import re
import shutil
import subprocess
import sys

ICI = os.path.dirname(os.path.realpath(__file__))
# Arborescence de l'image : /usr/local/lib/nomade/nomade_diag → /usr/local/share/nomade ;
# dans le dépôt : config/rootfs/usr/local/lib/nomade/nomade_diag → config/rootfs/usr/local/share/nomade.
PARTAGE = os.path.normpath(os.path.join(ICI, "..", "..", "..", "share", "nomade"))


def log(*msg):
    print("[%s]" % datetime.datetime.now().strftime("%H:%M:%S"), *msg, file=sys.stderr, flush=True)


def lire(chemin, defaut=""):
    """Contenu d'un fichier texte, sans blancs autour ; défaut si illisible."""
    try:
        with open(chemin, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return defaut


def entier(texte, base=10):
    try:
        return int(str(texte).strip(), base)
    except (TypeError, ValueError):
        return None


def commande(args, delai=10, entree=None, env=None):
    """(code, sortie standard, erreur) ; code None si la commande est absente ou trop longue."""
    if shutil.which(args[0]) is None:
        return None, "", "%s absent" % args[0]
    # Sorties en anglais, stables d'une langue à l'autre (lscpu, systemd-analyze…)
    env = dict(env if env is not None else os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
    try:
        p = subprocess.run(args, input=entree, capture_output=True, text=True, timeout=delai,
                           errors="replace", env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return None, "", "délai de %s s dépassé" % delai
    except OSError as e:
        return None, "", str(e)


def sortie(args, delai=10):
    """Sortie standard d'une commande (vide en cas d'échec)."""
    code, out, _ = commande(args, delai)
    return out if code == 0 else ""


def maintenant():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def horodatage():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M")


def reduire(texte, n=40):
    """Nom de fichier : minuscules ASCII, chiffres et tirets."""
    t = texte.lower()
    for a, b in (("àâä", "a"), ("éèêë", "e"), ("îï", "i"), ("ôö", "o"), ("ùûü", "u"), ("ç", "c")):
        for c in a:
            t = t.replace(c, b)
    t = re.sub(r"[^a-z0-9]+", "-", t).strip("-")
    return t[:n].strip("-") or "inconnu"


def arrondi(x, n=1):
    return None if x is None else round(float(x), n)


def valeurs_env(chemin):
    """Fichier clé=valeur (build-info, deploy-info) en dictionnaire."""
    d = {}
    for ligne in lire(chemin).splitlines():
        ligne = ligne.strip()
        if ligne and not ligne.startswith("#") and "=" in ligne:
            k, v = ligne.split("=", 1)
            d[k.strip()] = v.strip().strip('"')
    return d


def est_root():
    return os.geteuid() == 0
