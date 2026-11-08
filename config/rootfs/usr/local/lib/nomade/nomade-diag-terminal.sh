#!/usr/bin/env bash
# Lanceur « Diagnostic de la clé » du menu (E-46) : nomade-diag dans un terminal qui reste
# ouvert à la fin, sur le résumé et le chemin de l'archive.
printf 'Diagnostic de la clé zorin-nomade : PC, démarrage, clé, erreurs (≈ 1 min).\n'
printf 'Rien n'"'"'est modifié sur ce PC ; le rapport est anonymisé.\n\n'
rc=0
/usr/local/bin/nomade-diag "$@" || rc=$?
echo
if ((rc == 0)); then echo "Terminé."; else echo "Diagnostic interrompu (code $rc)."; fi
read -r -p "Entrée pour fermer cette fenêtre. " _
