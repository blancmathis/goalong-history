# Analyses locales : contrat et lecture des chiffres

La référence produit est la landing page Goalong (`index.html`, scènes Usages,
Rythme, Projets, Journée, Évolution), et non le tableau de bord web en chantier.

## Ce qui est disponible

L’entrée **Analyses**, accessible aussi depuis Aujourd’hui, réunit les périodes
Jour, 7 jours et 28 jours, la répartition des usages, le focus observé, les
séquences continues, les changements de contexte, les courbes et une comparaison
avec la période précédente de même durée. Une journée peut être ouverte depuis
le graphique ou sa liste accessible au clavier.

Les projets, types de travail, méthodes, avancées, prochaines étapes, usage de
l’IA et récapitulatifs proviennent uniquement d’analyses déjà enregistrées dans
History. Les cartes gardent leur statut Observé, Déduit, Déclaré ou À préciser.
Le bouton Comprendre mon travail ouvre le studio existant dans un mode local :
sélection explicite, consentement avant l’agent, relecture et conservation locale.
Aucun résultat n’est envoyé au site depuis ce mode.

## Définition des mesures (local-observed-rhythm-v1)

- Le temps actif est l’union, sans chevauchement, des intervalles entre événements
  consécutifs autorisés dans une même journée. Une observation ne prolonge jamais
  le temps avant la première trace ou après la dernière.
- Travail classé, Autres usages et À préciser partitionnent le temps actif. La
  classification existante est conservée seulement si sa confiance atteint 50 %.
  Autres usages ne signifie pas procrastination. Les versions du classificateur
  accompagnent les mesures pour limiter les comparaisons trompeuses.
- Une séquence de **focus observé** conserve la même application et le même
  domaine, avec une durée minimale de 10, 25 ou 50 minutes. La durée de la séquence
  entière est comptée, et non seulement la partie après le seuil. C’est un proxy
  de continuité, pas une mesure de concentration mentale ou d’efficacité. Les
  changements d’outil au sein d’un projet ne sont pas regroupés automatiquement.
- Un écart supérieur à 120 secondes, une rupture explicite, un arrêt/reprise,
  une suspension ou un signal d’inactivité interrompt la séquence. Un signal
  d’inactivité d’au moins 90 secondes est séparé du temps actif : il ne prouve
  ni une pause volontaire, ni du repos, ni une absence de travail hors écran.
- Les heures des sites sont incluses dans celles des navigateurs. Les heures de
  focus sont incluses dans le temps actif. Apple Screen Time, conversations et
  temps machine ne sont pas ajoutés aux durées de premier plan sur ce Mac.

## Couverture et confidentialité

Les jours manquants ne sont pas tracés à zéro et ne sont pas reliés par une
courbe. Les données futures ne sont pas fabriquées. Une lecture tronquée,
annulée, modifiée pendant le calcul ou inaccessible est exclue des totaux avec
un avertissement. La journée en cours est indiquée comme partielle.

Le lecteur borné existant est réutilisé, une journée à la fois. Sa nouvelle
projection ne retient ni titre de fenêtre, ni chemin/query d’URL, ni texte
sémantique, ni corps de conversation. Les résumés de mesure restent uniquement
en mémoire (au maximum deux périodes de 28 jours) ; les journaux sources ne
sont jamais réécrits. Seules les métadonnées de révision des fichiers servent
au cache des jours passés. Le jour courant est relu à l’actualisation.

Ouvrir cette page ne lance aucun agent, ne change aucun consentement, ne crée
aucun collecteur et ne transmet rien au site. Les analyses facultatives suivent
les consentements déjà en place. Les lectures de rapports conservés sont
bornées aux 64 dossiers récents valides, avec avertissement si la limite est
atteinte ; aucune copie des preuves n’est créée par la vue.

Le sport, le sommeil, les données de santé et les activités hors Mac ne sont pas
inférés à partir du temps écran. Leur visualisation détaillée nécessite des
sources distinctes et n’est pas ajoutée par cette version.
