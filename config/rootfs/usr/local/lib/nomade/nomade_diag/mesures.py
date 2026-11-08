"""Mesures d'E/S, protocole de Fabrique-Clé (app/src/diagnostic/mesures.rs et analyse.rs) :
mêmes tailles de blocs, mêmes durées, mêmes classes d'histogramme, pour que les chiffres des
deux outils se comparent.

Les E/S sont directes (O_DIRECT, tampons alignés sur une page par mmap) : sinon on mesurerait la
mémoire du PC. Chaque test est borné en durée, pas en volume. Les opérations simultanées passent
par des fils d'exécution, un descripteur chacun (os.preadv et os.pwritev libèrent le GIL).
"""

import mmap
import os
import random
import threading
import time

ALIGNEMENT = 4096
BLOC_ALEATOIRE = 4096
BLOC_SEQUENTIEL = 4 << 20
EN_PARALLELE = 8
CLASSES_US = [100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000]
DUREE_LECTURE_S = 8
DUREE_ECRITURE_S = 10


class Support:
    """Disque ou fichier ouvert ``n`` fois (un descripteur par fil)."""

    def __init__(self, chemin, ecriture=False, n=1, exclusif=False):
        self.chemin = chemin
        self.fds = []
        self.directes = True
        drapeaux = os.O_RDWR if ecriture else os.O_RDONLY
        for i in range(n):
            d = drapeaux | (os.O_EXCL if exclusif and i == 0 else 0)
            try:
                fd = os.open(chemin, d | os.O_DIRECT)
            except OSError:
                fd = os.open(chemin, d)          # E/S directes refusées : mesures peu fiables
                self.directes = False
            self.fds.append(fd)
        self.taille = os.lseek(self.fds[0], 0, os.SEEK_END)

    def fermer(self):
        for fd in self.fds:
            os.close(fd)
        self.fds = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.fermer()

    # Accès par position, comme Support::lire_a / ecrire_a / synchroniser
    def lire_a(self, buf, pos, i=0):
        n = os.preadv(self.fds[i], [buf], pos)
        if n != len(buf):
            raise OSError("lecture incomplète à %d (%d octets)" % (pos, n))

    def ecrire_a(self, buf, pos, i=0):
        n = os.pwritev(self.fds[i], [buf], pos)
        if n != len(buf):
            raise OSError("écriture incomplète à %d (%d octets)" % (pos, n))

    def synchroniser(self, i=0):
        os.fdatasync(self.fds[i])


def tampon(taille):
    """Zone mémoire alignée sur une page (exigence des E/S directes)."""
    return mmap.mmap(-1, taille)


def latences(liste_us):
    """Médiane, 90 %, 99 %, maximum et histogramme, comme Latences::depuis."""
    h = [0] * (len(CLASSES_US) + 1)
    for v in liste_us:
        i = next((k for k, b in enumerate(CLASSES_US) if v < b), len(CLASSES_US))
        h[i] += 1
    s = sorted(liste_us)
    q = lambda f: s[int(round((len(s) - 1) * f))] if s else 0
    return {"mediane_us": q(0.5), "p90_us": q(0.9), "p99_us": q(0.99), "max_us": s[-1] if s else 0,
            "histogramme": h}


def sequentielle(sup, duree=DUREE_LECTURE_S):
    """Lecture du début du disque par blocs de 4 Mio, pendant ``duree`` au plus."""
    buf = tampon(BLOC_SEQUENTIEL)
    zero = bytes(BLOC_SEQUENTIEL)
    debut = time.monotonic()
    pos = vides = blocs = 0
    serie = []
    tranche, octets_tranche = time.monotonic(), 0
    while time.monotonic() - debut < duree and pos + BLOC_SEQUENTIEL <= sup.taille:
        sup.lire_a(buf, pos)
        pos += BLOC_SEQUENTIEL
        octets_tranche += BLOC_SEQUENTIEL
        blocs += 1
        if buf[:] == zero:
            vides += 1
        if time.monotonic() - tranche >= 0.5:
            serie.append(round(octets_tranche / 1e6 / (time.monotonic() - tranche), 1))
            tranche, octets_tranche = time.monotonic(), 0
    duree_s = max(time.monotonic() - debut, 1e-6)
    return {"octets": pos, "duree_s": round(duree_s, 2), "mo_s": round(pos / 1e6 / duree_s, 1),
            "serie_mo_s": serie, "part_vide": round(vides / blocs, 3) if blocs else 0.0}


LECTURE, ECRITURE, ECRITURE_SYNCHRO = "lecture", "ecriture", "ecriture_synchro"


def aleatoire(sup, zone, duree, mode=LECTURE, n=1, max_ops=None):
    """Opérations de 4 Kio à des positions tirées au hasard dans ``zone`` (début, fin), ``n`` à
    la fois (fils 0..n-1 du support), pendant ``duree`` et, si donné, ``max_ops`` opérations au plus
    (plafond d'écriture de nomade-diag)."""
    premier = -(-zone[0] // BLOC_ALEATOIRE)
    blocs = zone[1] // BLOC_ALEATOIRE - premier
    if blocs <= 0:
        raise ValueError("zone trop petite")
    arret = threading.Event()
    resultats = [None] * n
    compte = [0]
    verrou = threading.Lock()
    zero = bytes(BLOC_ALEATOIRE)

    def fil(i):
        h = random.Random(int.from_bytes(os.urandom(8), "little"))
        buf = tampon(BLOC_ALEATOIRE)
        if mode != LECTURE:
            buf[:] = os.urandom(BLOC_ALEATOIRE)
        lat, vides, erreur = [], 0, None
        try:
            while not arret.is_set():
                if max_ops is not None:
                    with verrou:
                        if compte[0] >= max_ops:
                            arret.set()
                            break
                        compte[0] += 1
                pos = (premier + h.randrange(blocs)) * BLOC_ALEATOIRE
                t = time.perf_counter_ns()
                if mode == LECTURE:
                    sup.lire_a(buf, pos, i)
                else:
                    # Contenu différent à chaque écriture (pas de déduplication)
                    buf[:8] = h.getrandbits(64).to_bytes(8, "little")
                    sup.ecrire_a(buf, pos, i)
                    if mode == ECRITURE_SYNCHRO:
                        sup.synchroniser(i)
                lat.append(min((time.perf_counter_ns() - t) // 1000, 2 ** 32 - 1))
                if mode == LECTURE and buf[:] == zero:
                    vides += 1
        except OSError as e:
            erreur = str(e)
        resultats[i] = (lat, vides, erreur)

    debut = time.monotonic()
    fils = [threading.Thread(target=fil, args=(i,), daemon=True) for i in range(n)]
    for f in fils:
        f.start()
    while time.monotonic() - debut < duree and all(f.is_alive() for f in fils):
        time.sleep(0.1)
    arret.set()
    for f in fils:
        f.join()
    duree_s = max(time.monotonic() - debut, 1e-6)
    toutes, vides = [], 0
    for lat, v, erreur in resultats:
        if erreur:
            raise OSError("%s : %s" % (mode, erreur))
        toutes += lat
        vides += v
    ops = len(toutes)
    iops = ops / duree_s
    r = {"en_parallele": n, "operations": ops, "duree_s": round(duree_s, 2), "iops": round(iops),
         "mo_s": round(iops * BLOC_ALEATOIRE / 1e6, 2)}
    r.update(latences(toutes))
    if mode == LECTURE:
        r["part_vide"] = round(vides / ops, 3) if ops else 0.0
    return r


def lecture(chemin, duree=DUREE_LECTURE_S):
    """Les trois tests en lecture seule (rien n'est jamais écrit) : séquentielle, aléatoire
    une à la fois, aléatoire EN_PARALLELE à la fois."""
    with Support(chemin, ecriture=False, n=EN_PARALLELE) as sup:
        r = {"directes": sup.directes, "taille_octets": sup.taille}
        r["sequentielle"] = sequentielle(sup, duree)
        r["aleatoire_1"] = aleatoire(sup, (0, sup.taille), duree, LECTURE, 1)
        r["aleatoire_%d" % EN_PARALLELE] = aleatoire(sup, (0, sup.taille), duree, LECTURE, EN_PARALLELE)
    a1, an = r["aleatoire_1"]["iops"], r["aleatoire_%d" % EN_PARALLELE]["iops"]
    r["gain_parallele"] = round(an / a1, 2) if a1 else None
    return r


# --- Écriture longue et profil du débit (analyse.rs) ------------------------------------------

def _mediane(v):
    if not v:
        return 0.0
    t = sorted(v)
    return float(t[len(t) // 2])


def _chute(debits, debut, depuis):
    """Premier point où la moyenne glissante passe sous la moitié du débit de référence et où la
    suite reste basse (fin du cache SLC)."""
    fenetre = 4
    if len(debits) < 12 or debut <= 0:
        return None
    for i in range(max(depuis, 6), len(debits) - fenetre + 1):
        if debits[i] >= debut * 0.5:
            continue
        glissante = sum(debits[i:i + fenetre]) / fenetre
        if glissante < debut * 0.5 and _mediane(debits[i:]) < debut * 0.6:
            return i
    return None


def _plateau(debits):
    fenetre = 5
    moitie = debits[:-(-len(debits) // 2)]
    if len(moitie) < fenetre:
        return _mediane(debits)
    return max(_mediane(moitie[i:i + fenetre]) for i in range(len(moitie) - fenetre + 1))


def profil(points):
    """(débit de début, débit de fin, octets écrits avant la chute ou None) ; ``points`` :
    [(Go écrits, Mo/s)], un par demi-seconde."""
    if not points:
        return 0.0, 0.0, None
    debits = [p[1] for p in points]
    fin = _mediane(debits[max(0, len(debits) - 6):])
    reference = _plateau(debits)
    entree = next((i for i, d in enumerate(debits) if d >= reference * 0.8), 0)
    i_chute = _chute(debits, reference, entree + 1)
    debut = _mediane(debits[entree:max(i_chute if i_chute is not None else len(debits), entree + 1)])
    chute_apres = int(points[i_chute - 1][0] * 1e9) if i_chute else None
    return debut, fin, chute_apres


def ecriture_longue(sup, zone, duree, plafond_octets=None):
    """Écriture séquentielle par blocs de 4 Mio dans ``zone``, pendant ``duree`` au plus (et au plus
    ``plafond_octets``)."""
    buf = tampon(BLOC_SEQUENTIEL)
    buf[:] = os.urandom(BLOC_SEQUENTIEL)
    h = random.Random(int.from_bytes(os.urandom(8), "little"))
    debut = time.monotonic()
    pos = -(-zone[0] // BLOC_SEQUENTIEL) * BLOC_SEQUENTIEL
    depart = pos
    points = []
    tranche, octets_tranche = time.monotonic(), 0
    while (time.monotonic() - debut < duree and pos + BLOC_SEQUENTIEL <= zone[1]
           and (plafond_octets is None or pos - depart < plafond_octets)):
        for i in range(16):        # contenu différent pour chaque bloc
            o = i * (BLOC_SEQUENTIEL // 16)
            buf[o:o + 8] = h.getrandbits(64).to_bytes(8, "little")
        sup.ecrire_a(buf, pos)
        pos += BLOC_SEQUENTIEL
        octets_tranche += BLOC_SEQUENTIEL
        if time.monotonic() - tranche >= 0.5:
            d = octets_tranche / 1e6 / (time.monotonic() - tranche)
            points.append([round((pos - depart) / 1e9, 3), round(d, 1)])
            tranche, octets_tranche = time.monotonic(), 0
    sup.synchroniser()
    duree_s = max(time.monotonic() - debut, 1e-6)
    octets = pos - depart
    d_debut, d_fin, chute = profil(points)
    return {"octets": octets, "duree_s": round(duree_s, 1), "mo_s": round(octets / 1e6 / duree_s, 1),
            "debit_debut_mo_s": round(d_debut, 1), "debit_fin_mo_s": round(d_fin, 1),
            "chute_apres_octets": chute, "points": points}
