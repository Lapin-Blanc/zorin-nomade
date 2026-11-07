# À faire de ton côté (hôte)

Tenu à jour par Claude. Rien ici ne bloque le run autonome sauf mention contraire.

## État de l'hôte (`make doctor`, 2026-11-07)

- Outils, KVM, OVMF (Secure Boot avec clés Microsoft), espace disque (111 Gio libres) : **tout est
  en ordre**, aucun paquet à installer.
- **Groupes `docker` et `libvirt`** : tu as choisi de les garder (D-019). `make doctor` affiche donc
  `[KO]` sur ce point et sort en erreur : c'est attendu. Claude n'utilise ni docker, ni podman, ni
  libvirt. Pour revenir sur ce choix plus tard : `sudo gpasswd -d fabien docker` (et `libvirt`),
  puis reconnexion.
- **Règles `deny` inactives** : `.claude/settings.json` ne contient que `allow: Bash(*)` ; les
  règles d'origine sont dans `.claude/settings copy.json`. Laissé tel quel à ta demande (D-019).
  En run autonome (`--dangerously-skip-permissions`), seules les consignes de `CLAUDE.md` protègent
  alors l'hôte (le `README` dit le contraire sur ce point). Pour les réactiver : fusionne le bloc
  `deny` de la copie dans `settings.json` (les `deny` l'emportent sur `allow`).
- **Mémoire** : 7 Gio de RAM. La VM de build et les VM de test ont été ramenées à 3 Gio (D-016).
  Pendant `make all`, fermer quelques onglets de Brave ou fenêtres de VS Code aide.

## Avant ou pendant le run autonome

- [ ] **Dépôt GitHub pour la CI (phase 4, D-023)** : crée le dépôt (public de préférence : minutes
      Actions gratuites et artefacts sans quota), puis
      `git remote add origin git@github.com:Lapin-Blanc/zorin-nomade.git && git push -u origin main`.
      Claude ne pousse pas de lui-même. Si tu veux qu'il pousse et vérifie la CI pendant le run,
      dis-le dans le texte de lancement (`prompts/run.md`).

## Après le run

- Voir `README.md` § 5 (déploiement sur la clé, `sudo make deploy KEY=…`) et la checklist du
  premier démarrage natif dans `docs/RAPPORT.md`.
- Pont SSK `090c:2320` : le projet Debian l'a vu instable en UAS sur le HP ProBook pendant `mkfs`.
  Le déploiement écrit par `bmaptool` ; en cas de déconnexions, le contournement côté hôte est le
  quirk `usb-storage.quirks=090c:2320:u` (perd le TRIM pendant le déploiement seulement).
