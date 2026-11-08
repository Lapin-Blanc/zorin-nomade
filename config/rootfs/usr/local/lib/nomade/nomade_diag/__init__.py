"""zorin-nomade — diagnostics (D-047, D-048).

Module commun à trois outils, bibliothèque standard seule, lancés par
``python3 -I -B /usr/local/lib/nomade/diag.py <outil> …`` :

- ``cle``      : diag-cle, sur l'hôte, avant le déploiement (identification, lectures,
                 analyse complète qui efface la clé) ;
- ``systeme``  : nomade-diag, sur la clé déployée ;
- ``rapport``  : diag-rapport, sur l'hôte, rassemble les résumés dans docs/terrain.md.

Les rapports sont anonymisés par défaut (anonymat.py) et portent un resume.json au schéma
stable (SCHEMA) : dans un même numéro, on ajoute des champs, on n'en retire ni n'en renomme
aucun.
"""

SCHEMA = 1
