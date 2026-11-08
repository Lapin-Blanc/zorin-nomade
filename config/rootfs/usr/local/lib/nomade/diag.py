"""zorin-nomade — point d'entrée des diagnostics (D-047) :

    python3 -I -B /usr/local/lib/nomade/diag.py cle|systeme|rapport|empreinte-cle|verdict-cle [options]

-I : ni variables d'environnement Python, ni dossier courant dans le chemin d'import ; le dossier
de ce fichier est ajouté explicitement. -B : pas de __pycache__ (ni dans l'image, ni dans le dépôt).
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))


def principal():
    outils = ("cle", "systeme", "rapport", "empreinte-cle", "verdict-cle")
    if len(sys.argv) < 2 or sys.argv[1] not in outils:
        print("usage : diag.py %s [options]" % "|".join(outils), file=sys.stderr)
        return 64
    outil = sys.argv[1]
    if outil == "cle":
        from nomade_diag.diag_cle import main
    elif outil == "systeme":
        from nomade_diag.systeme import main
    elif outil == "rapport":
        from nomade_diag.rapport import main
    elif outil == "empreinte-cle":
        from nomade_diag.rapport import main_empreinte as main
    else:
        from nomade_diag.rapport import main_verdict as main
    return main(sys.argv[2:])


if __name__ == "__main__":
    sys.exit(principal())
