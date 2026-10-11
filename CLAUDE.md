# Itération locale — Goalong

- `make dev` compile en debug pour l’architecture du Mac, sans clean, tests ni audit automatiques, puis ferme normalement Goalong et lance `.build/dev/Goalong History.app`. SwiftPM conserve son cache dans `.build/dev/swiftpm` ; log : `.build/dev/build.log`. La signature est vérifiée avant chaque basculement.
- `make dev-stop` ferme la copie de développement et relance `/Applications/Goalong History.app`. Une seule instance à la fois ; un blocage actif peut refuser la fermeture : le résoudre dans l’app, jamais forcer la terminaison.
- Même bundle id et certificat Apple Development que la release pour conserver l’identité TCC. L’app installée et sa clé doivent être disponibles ; aucun repli ad-hoc. Aucun changement au trousseau ni au bundle installé.
- La copie dev utilise les **vraies données et préférences utilisateur** et les permissions existantes. Les fonctions activées continuent normalement ; ce n’est pas un bac à sable. Sparkle et les migrations d’installation sont désactivés uniquement dans cette copie.
- Après modification : tests pertinents et `make audit` ; après ajout d’un fichier Swift dans l’app, `python3 scripts/generate_support_source_allowlist.py`. `make clean` supprime aussi le cache dev : quitter la copie dev avant.
- Les deux commandes sont exclusives. Après une interruption, vérifier qu’aucune commande ne tourne avant de supprimer le dossier `.build/dev/lock` resté présent.
- Déploiement : pousser sur `main` uniquement quand satisfait et autorisé. L’itération locale ne publie rien.
