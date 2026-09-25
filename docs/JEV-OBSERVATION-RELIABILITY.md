# Surveillance : continuité des vidéos et des fils sociaux

## Correction 0.6.47

Les observations périodiques et les interactions partagent désormais la même
interprétation du contexte. Une page vidéo au premier plan ne devient plus
« autre » lorsque le contrôle de lecture est momentanément absent ; cela ne
fabrique pas un signal « en lecture ». Un compositeur X ne devient plus un fil
social au battement suivant. La recherche, la messagerie et YouTube Studio
restent distingués de la consommation d’un fil.

Le contexte au premier plan est rafraîchi localement toutes les cinq secondes
pendant la surveillance. Un changement de contexte est admis immédiatement.
Les appels réseau restent sur les seules fenêtres distinctes de quinze secondes.
Le délai d’inactivité choisi, les preuves de lecture/appel, les pauses et les
frontières de confidentialité restent applicables. Une assertion globale du
navigateur n’identifie toujours pas l’onglet actif.

La sonde de lecture privilégie le contrôle focalisé et ses ancêtres, après avoir
vérifié leur appartenance à la fenêtre focalisée. Elle privilégie les contenus et
enfants visibles, conserve un plafond de 192 éléments et un budget de 100 ms,
et reconnaît davantage de libellés de lecture explicites français et anglais.
Les contrôles sont lus uniquement lorsque leur collecte est déjà autorisée.

## Données envoyées

Le contrat `observed-use-and-topic-v5` décrit chaque ligne par site, usage, titre,
actions observées et éventuellement texte visible. Les actions répétées sont
regroupées sans les effacer. Plusieurs sujets sous un titre X inchangé restent
plusieurs observations. Les exemplaires sans extrait sont fusionnés avec leurs
versions enrichies, mais un passage distinct sur un fil ne disparaît pas parce
que du code a ensuite été tapé.

Titre et extrait disposent de budgets séparés : le titre ne peut plus évincer
l’intégralité de l’extrait. Les niveaux de réduction sont 160/224, 96/160, 64/96
et 48/64 octets UTF-8 pour titre/extrait. Tous les critères explicitement
sauvegardés et tous les usages distincts sont conservés ; une fenêtre encore trop
complexe reste indéterminée, sans fabriquer un classement. Le JSON complet reste
borné à 1 600 octets. Le plafond fournisseur reste 999 tokens d’entrée et le seuil
de probabilité reste 0,80. Aucun classement n’est réalisé localement par blacklist.

## Extraits facultatifs et confidentialité

Les deux choix existants restent nécessaires : autoriser localement le texte
affiché ET autoriser son envoi comme bref extrait de surveillance. Rien n’est
activé automatiquement. La nouvelle sonde ne réutilise plus les captures locales
mixtes pouvant contenir du texte sélectionné ou une valeur de champ éditable.

La lecture AX est sérialisée hors du thread principal, avec un seul travail en
cours, un budget de 200 ms et 200 éléments au plus dans le parcours de contenu.
Seuls les rôles texte statique, titre et lien sont éligibles. Les sous-arbres
éditables, protégés et masqués, les barres d’outils et les textes hors du rectangle
visible sont exclus. Dans un navigateur, la lecture part du document de la fenêtre
focalisée, pas de la liste des autres onglets. Aucun screenshot, son, vidéo,
presse-papiers ou texte frappé n’est capturé par cette sonde.

Le contexte est à nouveau vérifié après le parcours. Un changement de génération,
de fenêtre, de contexte, d’exclusion, de permission ou de pause rejette le résultat.
Un extrait seul ne constitue jamais une preuve d’activité et ne déclenche aucun
appel. Les observations et extraits ne sont conservés que dans le tampon en mémoire.

## Validation et limites

`JevObservationPayloadTests` couvre conservation des actions/sujets, budgets
indépendants, Unicode, fenêtres et absence d’activité inventée.
`JevObservationRuntimeTests` couvre douze fenêtres adjacentes sans clavier,
lecture après expiration de l’inactivité, refus des assertions d’arrière-plan,
composition/recherche/messagerie, consentements, génération et visibilité.
Les tests sémantiques réels sont facultatifs, explicitement activés avec
`GOALONG_JEV_LIVE_EVALUATION=1` et n’envoient que des fixtures synthétiques.

Les tests de code ne prouvent pas une précision parfaite du modèle. Une page qui
n’expose pas ses contrôles ou son contenu peut encore rester indéterminée. Les
vidéos sans contrôle observable restent soumises au délai d’inactivité choisi.
L’absence d’extraits autorisés ne bloque pas l’analyse des domaines, modes et
titres déjà disponibles. Les limites de lecture AX sont des garde-fous de coût,
non une garantie d’observation exhaustive de tout navigateur.
