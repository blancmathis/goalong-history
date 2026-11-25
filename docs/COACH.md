# Conseil de journée à la demande

Le guide et son agenda fonctionnent localement sans modèle. Le conseil est une aide
facultative, désactivée par défaut, pour examiner la journée et choisir la suite. Il
ne lance aucune analyse au démarrage, à l'ouverture d'une page, à une heure donnée
ou après un événement d'agent.

## Parcours

1. Dans les réglages du guide, choisir **ChatGPT connecté** ou **Agent externe**.
2. Pour ChatGPT, utiliser la connexion et le consentement natifs d'Analyse ChatGPT.
   Lire le catalogue, puis choisir un modèle et un effort. Cette lecture ne crée
   ni fil ni tour de génération. Aucun identifiant de modèle n'est choisi dans les
   valeurs par défaut publiques.
3. Choisir les catégories de données et une limite de demandes (2 par défaut,
   de 1 à 6). Activer l'affichage de la carte de conseil.
4. Dans la journée, ajouter éventuellement une courte note, puis vérifier l'aperçu.
   Le second bouton, **Envoyer cette demande**, déclenche une seule génération.
5. Lire le constat, la prochaine action, un ajustement éventuel et zéro ou une
   question. La réponse ne modifie jamais le plan, les processus ou les blocages.

Une action de plusieurs agents peut avancer en parallèle. Le conseil distingue
ces processus de l'attention humaine nécessaire pour lancer, documenter, filmer,
répondre et relire. Il n'infère aucune réussite à partir du simple temps écoulé.

## Données choisies et aperçu exact

La sélection porte uniquement sur le plan rédigé dans Goalong :

| Réglage | Champs admissibles |
| --- | --- |
| Actions | Intention, titre, état, projet, prochaine action, critère de fin, nature et estimation |
| Agenda | Fuseau, bornes du travail flexible, marge, titre, heures, ancrage fixe et état de 24 plages au maximum |
| Processus | Titre, état et indicateur d'attente d'une réponse, 12 processus au maximum ; ceux qui attendent une réponse ou une relecture sont prioritaires |
| Bilan | Note du jour et première action du lendemain ; désactivé par défaut |
| Note de la demande | Texte facultatif saisi pour cette demande, 1 000 caractères au maximum |

Les URL, identifiants externes, messages des agents, questions/réponses brutes,
documents liés et historique observé du Mac ne sont jamais lus par ce constructeur.
Les consignes détaillées d'une plage ne sont pas récupérées. Les données saisies
explicitement dans le plan restent de la sélection utilisateur : les exclusions
d'applications et domaines ne sont pas un filtre sémantique de ce texte libre.
Le masque de noms choisi dans Analyse ChatGPT est appliqué avant l'aperçu.

Le total des consignes et du JSON est limité à 12 000 caractères ; le JSON est
aussi borné à 48 000 octets. Les éléments omis sont comptés dans le JSON. Si le
texte ne rentre pas, les plages de fin, puis les derniers processus, puis les
dernières actions sont retirés jusqu'à respecter la limite. Aucun document
supplémentaire n'est consulté pour compenser.

L'aperçu affiche les consignes et le JSON réellement passés au transport. Le
modèle, l'effort, le schéma de sortie et les contraintes d'exécution sont les
paramètres du transport, sans contenu personnel supplémentaire. La révision des
masquages/exclusions, le réglage du coach, le plan et le bilan sont revérifiés
immédiatement avant envoi. Une sélection périmée exige un nouvel aperçu.

Les réponses restent en mémoire. Si le plan avance pendant une génération, le
conseil conserve la révision d'origine et la carte signale que le plan a évolué ;
il reste une proposition. Une modification des autorisations ou des réglages
invalide le résultat et interrompt la demande.

## Usage et stockage

- Une seule opération de coach à la fois, y compris la lecture du catalogue.
- Aucune relance de génération automatique par Goalong, ni escalade de modèle.
- Réponse structurée en quatre textes, chacun borné au quart de la limite choisie
  (1 400 caractères au total par défaut, réglable de 600 à 4 000).
- Le transport conserve ses contrôles de schéma et limite les octets reçus. Ces
  limites ne sont pas un plafond exact des tokens de raisonnement du fournisseur.
- Les limites du compte sont lues avant la demande ; une limite proche arrête
  l'opération avant l'envoi.
- L'essai est écrit durablement juste avant l'envoi du tour. Échec, annulation ou
  arrêt de l'application ne le remboursent pas. Une erreur de stockage interdit
  l'envoi. Un redémarrage ne remet pas le compteur à zéro.
- Le jour du compteur suit le calendrier local du Mac, indépendamment du fuseau
  choisi pour l'agenda.
- `Focus/coach/usage.json` contient seulement identifiant de tentative, date,
  instant et total de tokens s'il a été communiqué. Aucun prompt, résultat,
  identifiant de compte ou secret. Fichier privé, écriture atomique, lectures
  sans suivi des liens symboliques ; conservation bornée à 90 jours usuels.
- Le nombre de tokens connu reste un compte partiel lorsque certains essais
  n'ont pas fourni leur usage. Il n'est jamais affiché comme un coût financier.

Le classement du travail et les bilans historiques existants gardent leurs propres
contrats et budgets. Les demandes de conseil s'ajoutent à leur consommation du
compte ; la limite locale du coach n'est pas une limite globale du fournisseur.

## Contrat de configuration

`FocusSettings.coach` est optionnel pour lire les anciens fichiers ;
`coachSettings` fournit les valeurs inactives par défaut. Les mutations UI et CLI
passent par `ConcentrationController.updateCoachSettings(_:)`. Une configuration
ne crée pas de consentement ChatGPT et ne déclenche aucune inférence.

Champs JSON : `enabled`, `provider` (`chatGPT` ou `externalAgent`), `model`,
`reasoningEffort`, `dailyCallLimit`, `maximumOutputCharacters`, `includeTasks`,
`includeAgenda`, `includeProcesses`, `includeReview`.

Pour activer ChatGPT, modèle et effort sont obligatoires. Le catalogue renvoyé par
le compte fournit leurs valeurs possibles ; l'envoi revérifie la paire exacte.
Un modèle absent ou un effort incompatible échoue explicitement.

Lectures du runtime :

- `status(settings:)` : compteur local Codable, sans réseau.
- `models` : dernier catalogue lu en mémoire.
- `loadModels()` : lecture explicite `account/read` puis `model/list`, sans inférence.

## Fournisseurs et authentification

ChatGPT réutilise le pont existant de Goalong vers le binaire Codex officiel
épinglé, son profil d'authentification privé et le profil de permissions sans
outils. Le coach utilise son propre schéma et ses propres délais ; il ne modifie
pas le contrat des bilans historiques. Aucun shell, outil, plugin, navigateur,
fichier de projet ou capacité d'exécution n'est disponible dans ce fil éphémère.

La documentation OpenAI autorise la poursuite des intégrations app-server locales
ou open source existantes et recommande désormais Sign in with ChatGPT. Les
règles des services commerciaux/hébergés sont distinctes :
[Codex App Server, Auth endpoints](https://learn.chatgpt.com/docs/app-server),
[Sign in with ChatGPT pour les apps open source](https://developers.openai.com/siwc/token-sharing-open-source).

**Agent externe** est une autre façon de travailler : l'utilisateur ouvre son
agent dans Claude Code ou T3 et lui donne les commandes du CLI Goalong. Goalong
n'appelle pas Claude et ne gère pas ses identifiants. Le bouton de la carte copie
une consigne générique dans le presse-papiers à la demande de l'utilisateur.

Aucun fournisseur Claude API natif n'est proposé dans cette version. Il faudrait
une intégration API distincte et explicitement configurée. Les conditions
Anthropic différencient l'hébergement d'un binaire Claude Code intact,
authentifié directement par l'utilisateur, d'un produit qui route ses propres
requêtes à travers les identifiants/quotas Claude.ai. Ne pas transformer ce dernier
cas en option d'authentification cachée :
[Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance),
[Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview).
Ces liens ont été vérifiés le 25 novembre 2026.

## Vérification

`FocusDayCoachTests` utilise des sessions simulées et des dossiers temporaires :
aucune clé, connexion, inférence réseau ou fenêtre visible. La suite vérifie
l'inactivité par défaut, la sélection exacte et bornée, les masquages, les données
omises, la revalidation avant envoi, le compteur après erreur/redémarrage, le refus
de stockage corrompu ou symbolique, la concurrence, l'annulation et l'absence de
modification du plan.
