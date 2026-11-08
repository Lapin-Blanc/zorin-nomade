<!--
Reprise autonome dans VS Code (extension Claude Code), après la phase 1.

Préparation, une seule fois :
  1. Ouvre le DOSSIER du projet dans VS Code (Fichier > Ouvrir le dossier… > ~/Documents/DEV/zorin-nomade),
     pour que CLAUDE.md et .claude/settings.json (allow Bash(*)) soient pris en compte.
  2. Réglages VS Code (Ctrl+,) : cherche « Claude Code » et coche
     « Allow Dangerously Skip Permissions ».
  3. Dans le panneau Claude Code, choisis le mode « Bypass permissions » (sélecteur de mode sous la
     zone de saisie, ou Maj+Tab) : plus aucune demande de confirmation.
  4. Facultatif : /model pour choisir Opus.
  5. Ferme Brave et les applications inutiles (7 Gio de RAM, VM de 3 Gio).
Puis colle le texte ci-dessous.

Reprise après une coupure : nouveau message « Relis PLAN.md, DECISIONS.md et docs/JOURNAL.md,
et continue le plan en autonomie. »
-->
Reprise autonome du projet zorin-nomade : phases 2 à 5.

Lis CLAUDE.md, SPEC.md, PLAN.md, DECISIONS.md, docs/JOURNAL.md et docs/iso-notes.md avant d'agir.

État : phases 0 et 1 terminées (commit 5186d85). `make image` construit l'image en ~5 min dans la
VM de build (cache APT réutilisé) ; `make test` la démarre avec Secure Boot activé puis désactivé
(~1 min par essai) : écran de connexion GNOME atteint, 48 contrôles PASS ; restent E-21 (/tmp en
tmpfs) et E-26 (dconf), prévus en phase 2. Déjà tranché, ne pas défaire : D-029 (EFI/BOOT
resynchronisé par crochet APT), D-032 (/etc/default/grub restauré), D-033 (grub-install dévié :
jamais d'écriture NVRAM, mise à jour simulée bloquante au build).

Exécute le plan à partir de la première case non cochée (phase 2), jusqu'à la fin de la phase 5,
en autonomie complète. Ne me pose aucune question et n'attends aucune confirmation : prends la
décision la plus raisonnable, consigne-la dans DECISIONS.md et continue. Si un problème résiste à
3 tentatives, applique la règle de CLAUDE.md ([!] dans PLAN.md, analyse dans docs/JOURNAL.md) et
avance sur ce qui n'en dépend pas.

Règles strictes (CLAUDE.md) : jamais de root ni de sudo sur l'hôte ; jamais d'écriture sur un vrai
périphérique (make deploy / scripts/deploy.sh vers /dev/disk/by-id/… est réservé à moi, le
déploiement se teste uniquement par make deploy-test dans la VM) ; jamais docker, podman ni
libvirt ; rien à écrire ni à lancer dans reference/.

Ressources : l'hôte n'a que 7 Gio de RAM. Jamais la VM de build et une VM de test en même temps
(test-image.sh arrête la VM de build si besoin). Si la mémoire disponible reste trop basse pour un
essai, tu peux fermer Brave (kill -TERM du processus principal /opt/brave.com/brave/brave) et GNOME
Logiciels ; ne ferme jamais VS Code ni un processus claude. Commandes longues (build, tests,
deploy-test) en arrière-plan avec journal dans out/logs/, suivi filtré (tail, grep) : ne déverse
pas de longs journaux.

Phase 4 : il n'y a pas encore de dépôt GitHub et tu ne pousses rien. Fais passer `make ci` en local,
écris .github/workflows/image.yml, et note dans docs/A-FAIRE-FABIEN.md ce que je dois faire pour
l'activer.

Une phase n'est terminée que lorsque ses critères d'acceptation passent. Coche le plan, tiens le
journal et committe à chaque étape (make lint propre). Termine par docs/RAPPORT.md, avec la
checklist du premier démarrage natif, et une synthèse courte de ce qui reste à faire de mon côté.
