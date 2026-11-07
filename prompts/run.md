<!--
Lancement (depuis la racine du dépôt, après la phase 0) :
    claude --model opus --effort high --dangerously-skip-permissions
puis colle le texte ci-dessous.

Reprise après une limite d'usage ou une interruption :
    claude --continue --dangerously-skip-permissions
puis : « Relis PLAN.md, DECISIONS.md et docs/JOURNAL.md, et continue le plan. »
-->
Lis CLAUDE.md, SPEC.md, PLAN.md, DECISIONS.md, docs/JOURNAL.md et docs/iso-notes.md.

Exécute le plan à partir de la première case non cochée, jusqu'au bout, en autonomie
complète. Ne me pose aucune question : prends la décision la plus raisonnable, consigne-la
dans DECISIONS.md et continue. Respecte strictement les règles de sécurité de CLAUDE.md,
en particulier : jamais de root sur l'hôte, jamais de déploiement sur un vrai périphérique.

Une phase n'est terminée que lorsque ses critères d'acceptation passent. Coche le plan,
tiens le journal et committe à chaque étape. Termine par docs/RAPPORT.md.
