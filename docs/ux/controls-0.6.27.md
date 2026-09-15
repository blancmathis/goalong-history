# Goalong History 0.6.27 — contrôles et vérification

Les trois cartes principales des réglages ouvrent des destinations distinctes. Elles sont actionnables sur toute leur surface. Le retour aux réglages, les états de pause et le retour après connexion utilisent la destination attendue. Le défilement repart en haut à chaque changement de rubrique.

L’onboarding propose les détails d’enregistrement, texte affiché inclus, avant validation. Les réglages existants ne sont pas réactivés silencieusement. Le démarrage d’une source, l’analyse ChatGPT et l’envoi au site restent trois autorisations différentes.

La sélection d’analyse version 2 utilise des listes explicites d’applications, d’appareils et de dossiers. Les modes durée seule et détails choisis sont filtrés avant construction du contexte. Les remplacements littéraux sont appliqués localement avant les limites de longueur et avant transmission. Une référence de texte appartenant à une autre application est rejetée. Le texte observé est encodé pour ne pas fermer le marqueur de contexte du prompt. Les consignes de rédaction ne donnent aucun accès supplémentaire.

La préparation du partage suggère les appareils et applications disponibles, sans envoyer. Une sélection modifiée reste modifiée après actualisation. L’aperçu fonctionne sans connexion. Les domaines locaux ou invalides ne bloquent plus toute la liste. Une erreur de lecture des sites ne détruit pas les autres choix. Une programmation déjà autorisée n’est pas étendue silencieusement.

Le tableau de bord ne montre plus un faux historique vide simplement parce qu’une autre fenêtre prend le focus. Les lectures restent suspendues en arrière-plan ; les données affichées sont libérées à la fermeture, au masquage ou à la réduction de la fenêtre.

## Tests spécifiques

La suite de tests couvre les 1 024 combinaisons de champs, les remplacements avant troncature, le cas Unicode, les limites de taille, la protection des références de texte, la persistance et le refus des liens symboliques. Le rendu natif optionnel active seulement l’arbre d’accessibilité de son propre processus et presse les trois cartes et leurs boutons de retour ; aucune permission d’accès à une autre application n’est demandée.

`GoalongIntegrationSmokeTests` permet d’exercer le vrai transport contre `scripts/goalong_loopback_fixture.py`, qui écoute uniquement sur 127.0.0.1 et n’enregistre que les métadonnées du test. Un test distinct démarre le composant Codex avec un compte temporaire vide, sans utiliser les identifiants de l’utilisateur ni demander une analyse.

Les comptes et données personnels ne servent pas de données de test. Les preuves de compilation, tests, signature, remplacement et contrôle après lancement se trouvent dans le dossier local `qa/quality-0.6.27/`.
