"""Analyse complète d'une clé : **efface la clé** (diag-cle COMPLET=1, D-048).

Protocole de Fabrique-Clé (app/src/diagnostic/analyse.rs), plus un essai de TRIM réel :
1. capacité réelle : marqueurs sur une grille au pas puissance de deux, relus ;
2. essai de TRIM (ce que fera deploy.sh) ;
3. écritures aléatoires de 4 Kio, une puis 8 à la fois ;
4. écritures synchronisées ;
5. longue écriture séquentielle (cache SLC) ;
6. lectures aléatoires sur les données écrites ;
7. remise à vide (TRIM de toute la clé si possible, premier et dernier Mio à zéro).

L'appelant (scripts/diag-cle.sh) a déjà passé les garde-fous : assert_real_usb_target (numéro de
série tapé) sur une vraie clé, assert_test_target (DEPLOY_TEST=1) sur un fichier ou un loop.
"""

import glob
import os
import random
import struct

from . import mesures as M
from .commun import commande, entier, lire, log

MARQUEURS_MIN = 256
MAGIE = b"NOMADE-MARQUEUR\0"
MIO = 1 << 20


def positions(taille):
    """Grille de marqueurs : pas puissance de deux (une contrefaçon replie les adresses sur sa
    capacité réelle, presque toujours une puissance de deux), plus le tout dernier bloc."""
    bloc = M.BLOC_ALEATOIRE
    derniere = max(taille // bloc - 1, 0) * bloc
    pas = max(taille // MARQUEURS_MIN, bloc)
    pas = 1 << (pas.bit_length() - 1)
    p = [k * pas for k in range(derniere // pas + 1)]
    if p[-1] != derniere:
        p.append(derniere)
    return p


def marqueur(buf, session, pos, rang):
    """En-tête (magie, session, position, rang) puis octets propres à cette position."""
    rot = ((pos << 17) | (pos >> 47)) & (2 ** 64 - 1)
    corps = random.Random(session ^ rot).randbytes(len(buf))
    buf[:] = corps
    buf[0:16] = MAGIE
    buf[16:36] = struct.pack("<QQI", session, pos, rang)


def capacite(sup, taille):
    session = int.from_bytes(os.urandom(8), "little")
    pos = positions(taille)
    buf, attendu = M.tampon(M.BLOC_ALEATOIRE), M.tampon(M.BLOC_ALEATOIRE)
    erreurs, ecrits = 0, [False] * len(pos)
    for i, p in enumerate(pos):            # ordre croissant : en cas de repliement, les hauts écrasent les bas
        marqueur(buf, session, p, i)
        try:
            sup.ecrire_a(buf, p)
            ecrits[i] = True
        except OSError:
            erreurs += 1
    if erreurs == len(pos):
        raise OSError("aucun marqueur n'a pu être écrit : la clé refuse l'écriture")
    sup.synchroniser()
    corrects, fiable, repliement = 0, None, False
    for i, p in enumerate(pos):
        bon = False
        if ecrits[i]:
            try:
                sup.lire_a(buf, p)
                marqueur(attendu, session, p, i)
                if buf[:] == attendu[:]:
                    bon = True
                elif buf[0:16] == MAGIE and struct.unpack("<Q", buf[16:24])[0] == session \
                        and struct.unpack("<Q", buf[24:32])[0] != p:
                    repliement = True
            except OSError:
                erreurs += 1
        if bon:
            corrects += 1
        elif fiable is None:
            fiable = p
    return {"marqueurs": len(pos), "corrects": corrects, "fiable_octets": fiable if fiable is not None else taille,
            "repliement": repliement, "erreurs": erreurs,
            "conforme": corrects == len(pos) and erreurs == 0}


def _provisioning(dev):
    return glob.glob("/sys/block/%s/device/scsi_disk/*/provisioning_mode" % os.path.basename(dev))


def essai_trim(sup, dev):
    """TRIM d'1 Mio au début du disque, comme deploy.sh (provisioning_mode=unmap tenté le temps de
    l'essai, puis remis) ; renvoie (réussi, zéros relus après, cause)."""
    nom = os.path.basename(os.path.realpath(dev))
    pm = _provisioning(dev)
    ancien = lire(pm[0]) if pm else None
    if entier(lire("/sys/block/%s/queue/discard_max_bytes" % nom)) == 0 and pm:
        try:
            with open(pm[0], "w") as f:
                f.write("unmap")
        except OSError:
            pass
    try:
        if entier(lire("/sys/block/%s/queue/discard_max_bytes" % nom)) == 0:
            return False, None, "discard_max_bytes=0 (le pont n'annonce pas le TRIM)"
        buf = M.tampon(MIO)
        buf[:] = os.urandom(MIO)
        sup.ecrire_a(buf, 0)
        sup.synchroniser()
        code, _, err = commande(["blkdiscard", "-f", "-o", "0", "-l", str(MIO), dev], delai=60)
        if code != 0:
            return False, None, "blkdiscard, code %s : %s" % (code, err.strip() or "aucun message")
        sup.lire_a(buf, 0)
        return True, buf[:] == bytes(MIO), None
    finally:
        if pm and ancien:
            try:
                with open(pm[0], "w") as f:
                    f.write(ancien)
            except OSError:
                pass


def remise_a_vide(sup, dev, trim_ok):
    """TRIM de toute la clé si le TRIM passe ; dans tous les cas, premier et dernier Mio à zéro
    (plus de table de partitions ni de GPT de secours)."""
    methode = "zeros"
    if trim_ok:
        code, _, _ = commande(["blkdiscard", "-f", dev], delai=900)
        if code == 0:
            methode = "trim"
    zero = M.tampon(MIO)
    sup.ecrire_a(zero, 0)
    fin = (sup.taille // MIO - 1) * MIO
    if fin > 0:
        sup.ecrire_a(zero, fin)
    sup.synchroniser()
    return methode


def analyser(dev, duree_longue_s=60, duree_aleatoire_s=M.DUREE_ECRITURE_S):
    with M.Support(dev, ecriture=True, n=M.EN_PARALLELE, exclusif=True) as sup:
        taille = sup.taille
        r = {"directes": sup.directes, "taille_octets": taille}
        log("1/7 — capacité réelle : marqueurs sur toute la surface")
        r["capacite"] = capacite(sup, taille)
        zone = (0, min(max(r["capacite"]["fiable_octets"], M.BLOC_SEQUENTIEL * 4), taille))
        log("2/7 — essai de TRIM")
        r["trim_reel"], r["zeros_apres_trim"], r["trim_cause"] = essai_trim(sup, dev)
        log("3/7 — écritures aléatoires de 4 Kio, une puis %d à la fois" % M.EN_PARALLELE)
        r["ecriture_1"] = M.aleatoire(sup, zone, duree_aleatoire_s, M.ECRITURE, 1)
        r["ecriture_%d" % M.EN_PARALLELE] = M.aleatoire(sup, zone, duree_aleatoire_s, M.ECRITURE, M.EN_PARALLELE)
        log("4/7 — écritures synchronisées")
        r["ecriture_synchro"] = M.aleatoire(sup, zone, duree_aleatoire_s, M.ECRITURE_SYNCHRO, 1)
        log("5/7 — longue écriture séquentielle (%d s au plus)" % duree_longue_s)
        r["ecriture_longue"] = M.ecriture_longue(sup, zone, duree_longue_s)
        log("6/7 — lectures aléatoires sur les données écrites")
        ecrite = (0, max(r["ecriture_longue"]["octets"], M.BLOC_SEQUENTIEL))
        r["lecture_donnees"] = M.aleatoire(sup, ecrite, min(duree_aleatoire_s, 6), M.LECTURE, 1)
        log("7/7 — remise à vide")
        r["remise_a_vide"] = remise_a_vide(sup, dev, r["trim_reel"])
    return r
