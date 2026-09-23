# Surveillance : blocage du recorder et critères explicites

## Diagnostic du 24 septembre 2026

Un échantillonnage de l'application installée 0.6.40 a montré un blocage, pas une
exception fatale. L'application restait vivante sans répondre :

- Thread principal : `AppDelegate.installWorkspaceObservers`, notification de
  veille des écrans, puis `EventRecorder.onWriterQueue` / `DispatchQueue.sync`.
- Writer : `EventRecorder.persist` → `JevIngress.receive` → `JevIngress.boundary`
  → `NotificationCenter.post` → `NSOperation.waitUntilFinished`.

L'observateur de la frontière était enregistré sur `OperationQueue.main`.
La publication synchrone attendait donc le thread principal, lequel attendait le
writer. Aucun traitement réseau n'est nécessaire au déclenchement. La veille,
le verrouillage ou une frontière de confidentialité pouvaient rencontrer ce cycle.
Un rapport CPU distinct en 0.6.38 n'est pas une preuve de crash et n'a pas été
utilisé pour attribuer cette cause.

## Correction

La frontière invalide immédiatement le tampon et sa génération sous verrou, puis
relâche ce verrou. Seule la notification destinée à l'interface est différée sur
le thread principal. Le writer ne dépend plus de l'exécution de cet observateur.
L'observateur n'impose plus lui-même une attente sur `OperationQueue.main` ; son
traitement de l'état reste sur `MainActor`. Le journal et ses validations ne sont
ni supprimés ni désactivés. Les contrôles de génération refusent les résultats
anciens même avant la livraison de la notification.

`JevStabilityTests` tient volontairement le thread principal occupé pendant que
le writer traverse chacune des sept frontières. L'ancien mécanisme dépasse le
délai ; le nouveau rend la main et invalide le contexte immédiatement. Une rafale
de 1 000 frontières bloquées ne produit qu'une notification. Tous ces tests sont
synthétiques, sans historique utilisateur ni appel externe.

## Critères de productivité

La page propose « Ce qui est productif pour moi » avec projets/objectifs,
applications/sites et contenus/usages. Une seule rubrique suffit. L'enregistrement
est explicite, conserve les données en cas d'erreur et invalide les réponses déjà
en cours. Le format v1 (description de projet) reste lisible ; il est enrichi lors
d'un enregistrement sans inventer de nouveaux critères.

Les trois textes restent locaux dans le fichier privé existant (0600), et sont
transmis en entier, comme champs distincts, uniquement pendant une surveillance
autorisée. Limite totale : 800 octets UTF-8 pour les critères. L'enveloppe JSON
complète passe de 800 à 1 600 octets afin de conserver les critères et les sujets
observés. Une fenêtre trop complexe est ignorée, jamais tronquée par suppression
de règles. Le plafond accepté déclaré par le fournisseur reste 999 tokens d'entrée
et un dépassement suspend les appels. La limite en octets n'est pas une garantie
mathématique sur le tokenizer interne non publié de TypeSafe.

Les critères de contenu explicites peuvent autoriser un cours ou une vidéo
particulière. Cela ne rend pas productif un fil social quelconque. Une application
ouverte ne constitue pas, à elle seule, une preuve de travail. Le modèle doit
comparer le sujet et l'usage aux critères ; des données manquantes restent
indéterminées. Les tests de code ne constituent pas une garantie de précision
sémantique du modèle sur tous les usages réels.
