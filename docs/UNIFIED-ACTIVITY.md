# Activité : lecture quotidienne et multi-jours

La navigation principale devient **Activité · Historique · Réglages**. Les routes
internes `overview` et `analytics` restent compatibles et ouvrent la même vue.
La route `activity` conserve son sens technique : l’historique ordinateur détaillé.
OverviewPage reste dans les sources pour ses projections et consommateurs
existants, mais n’est plus routée par la fenêtre principale.

## Lecture et navigation

Activité s’ouvre sur Jour, aujourd’hui. Jour / 7 jours / 28 jours commande toute la
projection Goalong. Les dates sont explicites. Les flèches avancent par périodes
calendaires, y compris lors des changements d’heure. Explorer un jour conserve un
retour vers la période initiale. Ce contexte reste dans la fenêtre lorsqu’on ouvre
Historique, Bilan ou Réglages.

Temps actif, Travail classé et Focus observé forment le premier niveau. Travail et
focus sont inclus dans l’actif ; ils ne s’additionnent pas. Une classification
inconnue est À préciser, pas un travail mesuré à zéro.

Une seule carte principale présente la chronologie, la lecture horaire ou les
jours d’une période. Les durées rares utilisent une échelle adaptée. Les valeurs
accessibles au clavier, seuils, séquences et changements restent disponibles à la
demande. Les usages et plages ouvrent un détail, puis un accès explicite aux traces.

Apps et sites partitionne les mêmes intervalles actifs que Par application : le
site remplace son intervalle de navigateur. Aucune durée Apple n’entre dans ce
classement. Les bilans et projets proviennent des archives existantes ; l’action
d’analyse permet de choisir le bilan quotidien ou les projets sans rien générer
avant les étapes existantes de sélection et d’accord.

Le Temps d’écran Apple reste distinct et daté. La vue multi-jours n’invente pas un
agrégat Apple : elle fournit un accès explicite à une journée. Les défauts d’accès
restent visibles après l’arrêt de lecture. Le rafraîchissement manuel met également
à jour la source Apple lorsque celle-ci est activée.

## Données et confidentialité

GoalongLocalAnalytics est le moteur commun, sans changement de collecte. Les
règles de LOCAL-ANALYTICS.md restent applicables : pas d’extrapolation, pas de double
comptage, pas de transformation des jours manquants en zéros, pas de conclusion sur
l’attention ou l’efficacité.

Les bilans quotidiens passent par le lecteur borné existant, au maximum une archive
par jour sélectionné. Cette lecture ne change pas le jour du runtime IA, ne
reconstruit pas son contexte, ne lance ni n’annule une génération. Les archives
illisibles ou incohérentes sont signalées.

Une actualisation de la même période conserve les derniers chiffres, leur heure
de lecture et une erreur visible si la mise à jour échoue. Changer de date, de
période ou de mode aperçu ne présente jamais les anciens chiffres sous le nouvel
intitulé. L’actualisation périodique est limitée à la page visible et au jour
courant, sans nouveau collecteur ou tâche de fond.

L’aperçu développeur reste désactivé par défaut, en mémoire, avec navigation
indépendante. Il sort avant les lectures de journaux et bilans. Apple n’est pas
instancié dans l’aperçu. Historique réel, analyse et partage y sont désactivés.

## Vérification

```sh
xcrun swift test --filter 'GoalongActivityTests|GoalongAnalyticsPreviewTests|GoalongLocalAnalyticsTests'
xcrun swift test
GOALONG_ANALYTICS_SNAPSHOTS="$PWD/qa/local-analytics" \
  xcrun swift test --skip-build --filter GoalongAnalyticsRenderingTests
```

Les rendus opt-in couvrent en-tête et contenu, clair/sombre, 640/1000 points :
jour, 7/28 jours, source absente, observation isolée, neuf secondes désordonnées et
période avec un jour manquant. Les tests utilisent des fixtures et dossiers
temporaires. Leurs résultats et les rendus doivent être vérifiés séparément ; ils
ne constituent pas une preuve de chaque interaction physique sur le Mac installé.

## Publication

Une fusion sur main ne prouve ni l’installation locale ni la publication du flux
de mise à jour. Le workflow doit conserver l’identité épinglée et la signature
Sparkle. En mode de signature locale, l’archive préparée nécessite le Mac autorisé
et le circuit existant de publication. Cette refonte ne modifie pas cette politique.
