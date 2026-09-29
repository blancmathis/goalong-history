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

## Lire une période en trente secondes (septembre 2026)

Le haut de la page répond d’abord aux questions simples, les détails restent dessous.

- **Quatre indicateurs** : Temps actif (total du jour, ou moyenne par jour observé sur 7/28 jours, avec heures de début et de fin), Travail (durée et part du temps actif, ou « À classer » tant que moins de la moitié du temps est classée), Concentration (plus long bloc de travail, ou à défaut plus longue période dans une même app ou un même site) et Changements d’app (par heure active, et intervalle moyen entre deux changements).
- **Comparaison honnête** : aujourd’hui est comparé à hier *à la même heure* ; un jour passé, à la veille ; une période, à la moyenne par jour observé de la période précédente. Les jours sans données ne comptent jamais comme des zéros.
- **À retenir** : jusqu’à sept constats chiffrés (amplitude ou horaires habituels médians, meilleure journée, créneau le plus actif, usage principal, rythme de changement, écart avec la période précédente, plus forte variation, part du travail).
- **Classement en un clic** : tant qu’au moins 15 % du temps reste à classer, une carte propose les principaux usages non classés avec *Travail* / *Hors travail*. Chaque ligne d’Applications et sites porte aussi une étiquette cliquable (Travail, Hors travail, automatique).
- **Rythme** : par heure, empilé Travail / Hors travail / À classer ; ou chronologie en couloirs (six usages principaux + Autres) pour voir quoi et quand. Sur 7/28 jours : barres par jour avec la moyenne en pointillés, et la carte **Quand êtes-vous actif ?** (minutes actives moyennes par jour de la semaine et par heure ; un jour de semaine sans observation reste vide).
- **Détail d’un usage** : classement modifiable, temps total et part, jours d’utilisation, séances (interruptions de plus de 2 min), durée moyenne, plus longue séance, évolution, heures d’utilisation et détail par jour.
- **Export** : *Exporter* enregistre un CSV (séparateur `;`, UTF-8 avec BOM) d’une ligne par jour et par app ou site : durées active, travail, hors travail, à classer, et classement appliqué. Aucun titre, adresse complète ni contenu ; les cellules commençant par `= + - @` sont neutralisées.

## Classement personnel

`GoalongUsageClassificationRules` associe une app (identifiant de bundle, sinon nom) ou un site (hôte, sous-domaines inclus) à *Travail* ou *Hors travail*. Le fichier privé `activity-classification.json` (0600) est lu par la page ; les journaux ne sont jamais réécrits. Les règles sont appliquées à chaque lecture sur les jours mis en cache : changer un choix met à jour tout l’historique instantanément, et le retirer restaure le classement automatique. Une règle de site prime sur celle de son navigateur ; l’hôte le plus précis gagne. Réglages → Apps et sites liste les choix et permet de tout réinitialiser. L’aperçu développeur n’applique jamais les règles réelles.

Un **bloc de travail** regroupe le temps classé Travail tant que les interruptions (autre usage, pause, absence d’observation) durent au plus deux minutes ; seules les secondes de travail sont comptées. Le **focus observé** historique (même app et même site sans interruption) reste disponible dans les détails.

## Journées très chargées

Une journée réelle peut dépasser 40 000 observations. La projection Activité, compacte, dispose désormais de son propre plafond (262 144 lignes, 384 Mio estimés) au lieu de celui de l’historique détaillé (32 768 lignes) qui rejetait ces journées entières comme « illisibles ». La lecture reste bornée, une journée à la fois, et les journées passées sont mises en cache après leur première lecture.

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
