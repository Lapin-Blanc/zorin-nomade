"""Tests unitaires du module nomade_diag (make ci) : python3 -I -B tests/diag/test_diag.py

Sans root ni périphérique : supports simulés en mémoire (dont une contrefaçon qui replie les
adresses), archive dans un dossier temporaire.
"""

import os
import sys
import tempfile
import unittest

ICI = os.path.dirname(os.path.realpath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ICI, "..", "..", "config", "rootfs", "usr", "local", "lib", "nomade"))

from nomade_diag import analyse as A, anonymat, archive, materiel, mesures as M, verdict as V  # noqa: E402


class SupportMemoire:
    """Disque simulé ; ``reel`` < ``taille`` : contrefaçon (adresses repliées modulo ``reel``)."""

    def __init__(self, taille, reel=None):
        self.taille = taille
        self.reel = reel or taille
        self.donnees = bytearray(self.reel)
        self.directes = True

    def _p(self, pos):
        return pos % self.reel

    def lire_a(self, buf, pos, i=0):
        p = self._p(pos)
        buf[:] = bytes(self.donnees[p:p + len(buf)])

    def ecrire_a(self, buf, pos, i=0):
        p = self._p(pos)
        self.donnees[p:p + len(buf)] = buf[:]

    def synchroniser(self, i=0):
        pass


class Table(unittest.TestCase):
    def test_table_lisible(self):
        t = materiel.charger_table()
        self.assertGreater(len(t), 30)
        sm = materiel.identification(t, 0x090C, 0x2320)
        self.assertEqual(sm["role"], "ssd")
        self.assertIn("SM2320", sm["nom"])
        self.assertEqual(sm["precision"], "modele")
        self.assertEqual(materiel.identification(t, 0x090C, 0x1000)["role"], "controleur")
        self.assertEqual(materiel.identification(t, 0x2109, 0x0715)["role"], "pont")
        self.assertIsNone(materiel.identification(t, 0x1234, 0x5678))

    def test_bridage(self):
        self.assertTrue(materiel.bridee_usb2("3.20", 480))
        self.assertFalse(materiel.bridee_usb2("3.20", 10000))
        self.assertFalse(materiel.bridee_usb2("2.00", 480))
        self.assertIsNone(materiel.bridee_usb2(None, 480))


class Mesures(unittest.TestCase):
    def test_latences(self):
        r = M.latences(list(range(1, 1001)))
        self.assertEqual(r["mediane_us"], 501)
        self.assertEqual(r["p99_us"], 990)
        self.assertEqual(r["max_us"], 1000)
        self.assertEqual(sum(r["histogramme"]), 1000)
        self.assertEqual(r["histogramme"][0], 99)       # < 100 µs

    def test_profil_chute(self):
        # 20 s à 500 Mo/s puis 20 s à 100 Mo/s, un point par demi-seconde
        pts, go = [], 0.0
        for i in range(80):
            d = 500.0 if i < 40 else 100.0
            go += d * 0.5 / 1000
            pts.append([go, d])
        debut, fin, chute = M.profil(pts)
        self.assertAlmostEqual(debut, 500.0)
        self.assertAlmostEqual(fin, 100.0)
        self.assertAlmostEqual(chute / 1e9, 10.0, delta=0.3)

    def test_profil_sans_chute(self):
        pts = [[i * 0.25, 500.0] for i in range(1, 60)]
        self.assertIsNone(M.profil(pts)[2])

    def test_aleatoire_memoire(self):
        s = SupportMemoire(64 << 20)
        r = M.aleatoire(s, (0, s.taille), 0.3, M.LECTURE, 2)
        self.assertGreater(r["operations"], 0)
        self.assertEqual(r["part_vide"], 1.0)


class Capacite(unittest.TestCase):
    def test_grille(self):
        p = A.positions(1 << 30)
        pas = p[1] - p[0]
        self.assertEqual(pas & (pas - 1), 0)              # puissance de deux
        self.assertGreaterEqual(len(p), A.MARQUEURS_MIN)
        self.assertEqual(p[-1], (1 << 30) - 4096)

    def test_cle_saine(self):
        s = SupportMemoire(256 << 20)
        r = A.capacite(s, s.taille)
        self.assertTrue(r["conforme"])
        self.assertFalse(r["repliement"])

    def test_contrefacon(self):
        s = SupportMemoire(512 << 20, reel=128 << 20)
        r = A.capacite(s, s.taille)
        self.assertFalse(r["conforme"])
        self.assertTrue(r["repliement"])
        self.assertLessEqual(r["fiable_octets"], 128 << 20)


class Verdict(unittest.TestCase):
    def test_seuils(self):
        self.assertEqual(V.categorie_mesuree(0.05), "A")
        self.assertEqual(V.categorie_mesuree(1.5), "B")
        self.assertEqual(V.categorie_mesuree(5), "B-C")
        self.assertEqual(V.categorie_mesuree(20), "C")
        self.assertEqual(V.categorie_mesuree(40), "D")

    def test_estimation(self):
        pont = {"pilote": "usb-storage", "identification": {"role": "pont"}}
        self.assertEqual(V.categorie_estimee(pont, None), "C-D?")
        bot = {"pilote": "usb-storage", "identification": {"role": "marque"}}
        self.assertEqual(V.categorie_estimee(bot, None), "A-B?")
        uas = {"pilote": "uas", "discard_max_octets": 4096, "identification": None}
        self.assertEqual(V.categorie_estimee(uas, {"gain_parallele": 3.0}), "C-D?")

    def test_contrefacon_bloquante(self):
        an = {"capacite": {"conforme": False, "corrects": 10, "marqueurs": 300, "fiable_octets": 1 << 30,
                           "repliement": True}, "trim_reel": True}
        v = V.verdict({"capacite_octets": 64 << 30}, None, an, None, 31)
        self.assertEqual(v["categorie"], "contrefacon")
        self.assertFalse(v["deployable"])

    def test_trop_petite(self):
        v = V.verdict({"capacite_octets": 16 << 30, "pilote": "uas"}, None, None, None, 31)
        self.assertFalse(v["deployable"])


class Anonymat(unittest.TestCase):
    def setUp(self):
        self.a = anonymat.Anonymiseur(b"s" * 32, utilisateur="fabien")

    def test_secret_et_motifs(self):
        e = self.a.secret("cle", "SN0123456789AB")
        self.assertEqual(len(e), 16)
        t = self.a.nettoyer("série SN0123456789AB, mac 52:54:00:12:34:56, ip 192.168.1.20, "
                            "lo 127.0.0.1, v6 fe80::1c2b:3cff:fe4d:5e6f, /home/fabien/x, fabien@eica.be, "
                            "BIOS 01.03.00, heure 10:20:30")
        self.assertNotIn("SN0123456789AB", t)
        self.assertIn("«empreinte:cle:%s»" % e, t)
        self.assertNotIn("52:54:00", t)
        self.assertNotIn("192.168", t)
        self.assertIn("127.0.0.1", t)
        self.assertNotIn("fe80", t)
        self.assertIn("/home/utilisateur/x", t)
        self.assertNotIn("eica", t)
        self.assertIn("01.03.00", t)
        self.assertIn("10:20:30", t)
        self.assertEqual(self.a.trouvailles("t", t), [])
        self.assertTrue(self.a.trouvailles("t", "reste SN0123456789AB"))

    def test_generiques_ignores(self):
        self.assertIsNone(self.a.secret("pc", "To Be Filled By O.E.M."))
        self.assertIsNone(self.a.secret("pc", "0000000000"))

    def test_empreinte_stable_et_salee(self):
        b = anonymat.Anonymiseur(b"t" * 32)
        self.assertEqual(self.a.empreinte("pc", "X1"), self.a.empreinte("pc", "X1"))
        self.assertNotEqual(self.a.empreinte("pc", "X1"), b.empreinte("pc", "X1"))

    def test_sel(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "sous", ".sel")
            s1 = anonymat.lire_ou_creer_sel(f)
            self.assertEqual(anonymat.lire_ou_creer_sel(f), s1)
            self.assertEqual(os.stat(f).st_mode & 0o777, 0o600)


class Archive(unittest.TestCase):
    def test_aller_retour(self):
        with tempfile.TemporaryDirectory() as d:
            c = archive.ecrire(d, "essai", {"resume.json": archive.json_texte({"schema": 1, "é": "à"}),
                                            "brut/x.txt": "ok"})
            self.assertTrue(c.endswith(".tar.zst"))
            self.assertEqual(archive.lire_resume(c)["é"], "à")
            self.assertEqual(archive.lire_tout(c)["brut/x.txt"], "ok")
            self.assertEqual(os.listdir(d), ["essai.tar.zst"])


class Rapport(unittest.TestCase):
    """diag-rapport sur des résumés fictifs (fixtures de test, pas des relevés)."""

    def test_import_et_tableaux(self):
        from nomade_diag import rapport
        cle = {"schema": 1, "type": "cle", "date": "2026-11-08T17:00:00+01:00", "anonymise": True,
               "outil": {"version": "test"}, "options": {"mode": "lecture"},
               "cle": {"empreinte": "a" * 16, "vid_pid": "2109:0715",
                       "identification": {"role": "pont", "nom": "VIA Labs VL715 (probablement), pont"},
                       "usb": {"pilote": "usb-storage", "vitesse_mbps": 10000}, "trim_declare": False},
               "lecture": {"sequentielle": {"mo_s": 400}, "aleatoire_1": {"iops": 3000}, "gain_parallele": 1.1},
               "analyse": None,
               "verdict": {"categorie": "C-D", "certitude": "estimee", "deployable": True,
                           "alertes": [{"niveau": "attention", "texte": "essai"}]}}
        brut = dict(cle, anonymise=False, date="2026-11-08T18:00:00+01:00")
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "docs"))
            archive.ecrire(os.path.join(d, "diagnostics", "archives"), "diag-cle-1-2109-0715-aaaaaaaa",
                           {"resume.json": archive.json_texte(cle)})
            archive.ecrire(os.path.join(d, "diagnostics", "archives"), "diag-cle-2-brut",
                           {"resume.json": archive.json_texte(brut)})
            self.assertEqual(rapport.main(["--depot", d]), 0)
            self.assertEqual(len(os.listdir(os.path.join(d, "diagnostics", "resumes"))), 1)   # brut refusé
            with open(os.path.join(d, "docs", "terrain.md"), encoding="utf-8") as f:
                t = f.read()
            self.assertIn("2109:0715 VIA Labs VL715 (probablement)", t)
            self.assertIn("C-D (estimee)", t)
            self.assertIn("_(aucun diagnostic pour l'instant)_", t)          # pas encore de PC


if __name__ == "__main__":
    unittest.main(verbosity=1)
