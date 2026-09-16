# Goalong History 0.6.28 — corrections de parcours

## Fenêtres avec arguments stables
La présentation de l’envoi et de l’éditeur ChatGPT utilise un objet identifiable contenant à la fois la destination et les arguments. La date choisie et l’onglet demandé ne dépendent plus de deux états SwiftUI indépendants susceptibles d’être lus à des moments différents.

Le test natif ouvre une journée précise, lit la valeur de date du vrai contrôle macOS, puis ouvre directement les onglets Remplacements et Consignes par leurs actions accessibles. Il ferme chaque fenêtre avant la suivante et vérifie les retours.

## Configuration visible
Les dix familles de détails d’analyse précèdent la grande liste des applications. Leurs contrôles sont instanciés immédiatement dans une grille fixe, accessible au clavier et à l’inspection macOS. Les grandes listes d’applications conservent le chargement progressif. Une application autorisée aux détails, mais dont aucun champ n’est activé, l’indique clairement.

Les cartes occupent la largeur disponible. La recherche des réglages inclut les outils avancés et ignore les espaces superflus. Les dates, états principaux et commandes de la chronologie sont harmonisés en français.

## Validation sans élargissement
Une règle de remplacement sans texte à rechercher, mais avec un remplacement renseigné, est signalée avant enregistrement. Un remplacement vide reste un choix valable pour supprimer le texte recherché. Aucune modification des préférences ou des autorisations existantes n’est appliquée par la mise à jour.

La programmation quotidienne suspendue est distinguée d’un simple envoi ponctuel. L’aperçu reste local ; les confirmations d’envoi et les listes d’autorisation explicites sont conservées.

Les journaux de validation sont conservés dans `qa/quality-0.6.28/`. Les comptes personnels ne servent pas aux envois de test : le transport est exercé avec un serveur local et des données synthétiques.
