"""Archive d'un diagnostic : <nom>.tar.zst avec resume.json, rapport.txt, brut/…, journal/…

Écrite d'abord sous un nom temporaire, puis renommée : jamais d'archive à moitié écrite.
"""

import io
import json
import os
import subprocess
import tarfile
import time


def json_texte(objet):
    return json.dumps(objet, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def contenu_tar(fichiers):
    """Tar en mémoire : {chemin relatif: texte ou octets}."""
    tampon = io.BytesIO()
    with tarfile.open(fileobj=tampon, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for nom in sorted(fichiers):
            donnees = fichiers[nom]
            if isinstance(donnees, str):
                donnees = donnees.encode("utf-8")
            info = tarfile.TarInfo(nom)
            info.size = len(donnees)
            info.mtime = int(time.time())
            info.mode = 0o644
            info.uname = info.gname = "nomade"
            tar.addfile(info, io.BytesIO(donnees))
    return tampon.getvalue()


def ecrire(dossier, nom, fichiers, uid=None, gid=None):
    """Écrit ``dossier/nom.tar.zst`` ; renvoie son chemin."""
    os.makedirs(dossier, exist_ok=True)
    final = os.path.join(dossier, nom + ".tar.zst")
    temp = final + ".part"
    brut = contenu_tar(fichiers)
    with open(temp, "wb") as f:
        p = subprocess.run(["zstd", "-q", "-10", "-T0", "-c"], input=brut, stdout=f, check=False)
    if p.returncode != 0:
        os.unlink(temp)
        raise RuntimeError("compression zstd impossible (code %s)" % p.returncode)
    os.chmod(temp, 0o644)
    if uid is not None:
        try:
            os.chown(temp, uid, gid if gid is not None else -1)
        except OSError:
            pass                      # exFAT : propriétaire fixé au montage
    os.replace(temp, final)
    if uid is not None:
        try:
            os.chown(dossier, uid, gid if gid is not None else -1)
        except OSError:
            pass
    return final


def lire_resume(chemin):
    """resume.json d'une archive .tar.zst (dictionnaire)."""
    p = subprocess.run(["zstd", "-q", "-d", "-c", chemin], capture_output=True, check=False)
    if p.returncode != 0:
        raise RuntimeError("décompression impossible : %s" % chemin)
    with tarfile.open(fileobj=io.BytesIO(p.stdout), mode="r") as tar:
        membre = tar.getmember("resume.json")
        return json.loads(tar.extractfile(membre).read().decode("utf-8"))


def lire_tout(chemin):
    """Tous les fichiers texte d'une archive : {nom: texte}."""
    p = subprocess.run(["zstd", "-q", "-d", "-c", chemin], capture_output=True, check=False)
    if p.returncode != 0:
        raise RuntimeError("décompression impossible : %s" % chemin)
    d = {}
    with tarfile.open(fileobj=io.BytesIO(p.stdout), mode="r") as tar:
        for m in tar.getmembers():
            if m.isfile():
                d[m.name] = tar.extractfile(m).read().decode("utf-8", errors="replace")
    return d
