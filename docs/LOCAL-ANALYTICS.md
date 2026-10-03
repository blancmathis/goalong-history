# Activité : contrat et lecture des chiffres

Activité lit des observations locales de premier plan sur ce Mac, pour un jour, 7 jours
ou 28 jours, puis une période précédente de même durée. Les sources complémentaires
(Temps d’écran, conversations IA, rapports enregistrés) conservent leur propre sens.
Aucune ne rajoute de secondes au temps actif.

## Définition des mesures (local-observed-rhythm-v4)

- Le temps actif provient des intervalles entre événements consécutifs autorisés dans
  une même journée. Aucun temps n’est extrapolé avant la première ou après la dernière
  observation. Un écart supérieur à 120 secondes ou une rupture d’observation n’est
  jamais comblé.
- Travail, Hors travail et À classer partitionnent ce temps. La définition de travail
  de l’utilisateur, appliquée aux contextes par l’agent, fournit les verdicts ; aucune
  application n’est jugée productive. Les corrections s’appliquent à la lecture et les
  journaux ne sont pas réécrits. Voir [Mon travail](WORK_DEFINITION.md).
- La politique de présence enregistrée dans chaque événement moderne garde une fenêtre
  visible active jusqu’à l’expiration du délai de lecture choisi. Zéro correspond au
  mode écran allumé choisi explicitement. Une observation invisible ou une politique
  invalide ne constitue pas une présence. L’intervalle est coupé au moment exact de
  l’expiration, même si le prochain événement arrive plus tard.
- Une preuve positive de premier plan (appel, média en lecture, maintien de l’affichage)
  permet du temps actif sans frappe. Une assertion de processus navigateur ne prouve
  pas quel onglet est actif : la part du site reste bornée aux preuves du premier plan.
  Les journaux anciens gardent leur politique : sans présence moderne ni preuve passive,
  le seuil d’inactivité d’entrée reste 90 secondes. Aucune réunion ancienne n’est déduite
  du seul nom d’une application. Voir [Présence](FOREGROUND-ACTIVITY.md) et
  [Temps observé](FOREGROUND_SCREEN_TIME.md).
- Une séquence continue suit une tâche classée Travail à travers ses applications ; sinon
  elle suit une application et un domaine. Elle ne traverse jamais une période inactive,
  cachée ou inconnue. Le seuil de 10, 25 ou 50 minutes porte sur toute la séquence. Ces
  mesures décrivent la continuité, pas la concentration mentale ni l’efficacité.
- Les heures des sites font partie des heures des navigateurs. Les durées de sessions
  font partie du temps actif. Les métriques des agents et appareils restent distinctes.

## Couverture et ventilation

Chaque intervalle caché ou non observé porte sa raison : avant/après les observations,
trou supérieur à 120 secondes, trou signalé, arrêt, pause, veille, verrouillage,
permission Accessibilité, session indisponible, premier plan invisible, navigation privée,
application/site exclu, saisie sécurisée ou suppression d’historique. La raison distingue
les intervalles adjacents. Un jour absent, illisible ou ancien sans résumé porte un état
au niveau de la journée ; une absence ancienne ne prouve pas qu’un journal a existé.

`Day.coverage` et `Period.coverage` exposent les secondes observées, actives, inactives,
cachées et non observées, les secondes par raison (aussi séparément pour caché et non observé), les bornes des observations et l’origine.
Une lecture annulée, modifiée, inaccessible ou tronquée est `.incomplete`, sans total
plausible. La journée en cours s’arrête à l’heure de lecture.

`Day.breakdown` et `Period.breakdown` partitionnent les secondes actives par minute
calendaire, avec une seule catégorie par minute : appel > média > affichage maintenu >
clavier > pointeur > lecture sans entrée. Une preuve passive doit provenir d’un intervalle
réellement actif. Les frappes, raccourcis, clics et défilements ne gardent aucun contenu.
Des valeurs horaires sont disponibles, y compris les jours de changement d’heure.
La somme des modes est le temps actif ; ce n’est pas une nouvelle estimation de durée.

## Résumés durables et confidentialité

Les journées passées complètes sont conservées dans `activity-days/<yyyy-MM-dd>.json`
(schéma `goalong.activity-day.v1`, fichier 0600, dossier 0700, écriture atomique). Un résumé
contient les intervalles compacts, apps, identifiants, domaines, empreintes de contexte,
raisons de couverture et ventilation. Il ne contient ni titre de fenêtre, ni chemin/query
d’URL, ni texte visible, ni contenu de conversation, ni tâche dérivée d’un verdict.
Les verdicts courants s’appliquent encore à la lecture.

Le journal reste prioritaire lorsqu’il existe et que sa révision diffère du résumé.
Un résumé valide à révision identique évite une relecture ; sans journal, il est restauré
avec `Day.origin = .summary` et `hasDetailedSource = false`. Un résumé utilisé comme
cache d’un journal présent garde `hasDetailedSource = true`. Le jour courant n’est jamais sauvegardé comme résumé clos.
Le fuseau et la méthode doivent correspondre ; une incompatibilité ne fabrique aucune donnée.

Un rattrapage de faible priorité démarre trois minutes après le lancement et après un
changement de jour. Il traite les journaux passés un par un et peut être annulé. La purge
sauvegarde et relit un résumé valide immédiatement avant de supprimer un journal : si
la lecture ou l’écriture échoue, **le journal reste**. Limites : 20 000 intervalles et
2 Mio par résumé. Les résumés ont leur propre conservation, sans limite par défaut. Une durée finie
constitue un choix explicite d’effacement : le rattrapage ne recrée pas les résumés expirés.
La suppression ciblée invalide les résumés concernés ; vider l’historique enlève le dossier.
Les écritures de l’app passent par la même barrière que les autres données dérivées.

Ouvrir Activité peut déclencher le classement automatique des contextes si l’utilisateur
l’a autorisé et qu’un compte est connecté. La lecture des mesures elle-même ne lance
aucun agent ni envoi au site et n’ajoute aucun consentement. Les rapports déjà conservés
restent des interprétations ; ils ne changent pas les intervalles observés.
