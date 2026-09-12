# Analyse du profil : recette du 12 septembre 2026

Périmètre : sources Computer History et Conversation History choisies, rubriques autorisées, consigne fixe et restrictions personnelles, masquage, analyse réelle, conservation locale, sélection des cartes et transmission au site.

- Build installé : `0.6.0 / 20260912.4`, `/Applications/Goalong History.app`. Signature Apple Development vérifiée, exigence d’identité macOS inchangée, copie de retour arrière conservée dans `dist/before-verified-profile-20260912.4/`.
- Suite complète : 921 tests exécutés, 11 contrôles facultatifs ignorés, aucun échec. Les 26 contrôles de frontière réseau passent aussi. Journal : `/tmp/goalong-verified-profile-ui-build-final.log`.
- Le contrôle facultatif `GoalongLiveProfileAnalysisTests` a ensuite été exécuté séparément avec le vrai modèle et la connexion ChatGPT propre à Goalong : réussi. Six preuves fictives, dix rubriques, références vérifiées, exclusions et alias appliqués. Aucun historique personnel transmis. Journal : `/tmp/goalong-real-agent-final.log`.
- Les timestamps individuels disponibles sont conservés, y compris les millisecondes ; les dates absentes et les fenêtres de sélection restent distinguées. Une conversation ancienne n’est pas assimilée à un accomplissement du jour.
- L’interface installée ouvre le studio redimensionnable ; les sections ordinaires remplacent les GroupBox qui faisaient planter le service de contrôle de l’écran. Le même formulaire a été isolé pour confirmer cette cause.
- L’archive issue du vrai modèle se rouvre avec les exclusions, alias et consignes. Les dix cases de transmission sont initialement décochées. Seules Projets et Méthodes ont été sélectionnées. L’accord de relecture active l’export.
- Le bouton de conservation écrit un dossier privé en mode 0600. L’export produit par l’interface est identique au résultat validé par la CLI et les tests, sans preuves, timestamps privés ni règles.
- L’envoi depuis l’interface au site publié a reçu le message `Received: 1 new, 0 updated, 0 unchanged`. La lecture indépendante du serveur confirme exactement Projets et Méthodes, avec aucune règle de partage créée par cet envoi.
- Une règle publique temporaire a permis de vérifier les deux cartes sur le profil de test, à 752 et 390 pixels, sans débordement horizontal ni erreur de console. Les heures et applications restent non partagées.
- Le compte temporaire et son jeton sont supprimés. Le fichier de connexion initial est restauré. L’analyse fictive a été déplacée hors de l’historique personnel vers `/private/tmp/goalong-live-profile-acceptance/native-saved.analysis.json`. Aucun planificateur ni analyse de données personnelles n’a été activé.

Ces preuves valident ce parcours avec des données fictives. Les dix autres contrôles facultatifs de la suite par défaut ne sont pas annoncés comme exécutés ; les captures partielles et les conclusions du modèle conservent leurs limites explicites.
