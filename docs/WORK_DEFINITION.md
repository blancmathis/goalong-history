# Définition du travail — ce qui compte comme travail et classement par agent

Goalong ne décide jamais qu’une application ou un site est productif. Une même app
sert au travail puis à autre chose (YouTube pour un cours puis pour se distraire,
Messages pour un client puis pour des amis). Le travail est donc défini par
l’utilisateur, avec ses mots, et appliqué par un agent à ce qu’il faisait vraiment.

## Ce que voit l’utilisateur

- **Réglages › Définition du travail** (l’ancienne page « Mon travail ») : la définition (projets et objectifs, apps et sites
  et à quoi ils servent, contenus qui comptent comme travail, ce qui n’en est pas), l’état
  de l’agent, et « Vérifier et corriger » pour une journée.
- **Activité** : tuile Travail, carte **Tâches** (temps par projet, quelles que soient les
  apps), Concentration = plus longue session sur une même tâche, changements d’app « dont
  N sans quitter la tâche ». Sans définition, une carte invite à la rédiger.
- **Blocages › Jev** (la règle Jev) : affiche un résumé de la même définition et renvoie vers
  Réglages › Définition du travail. Il n’existe qu’une définition (`JevWorkContextStore`, 800 octets).

## Modèle

```text
journal (inchangé)
   │  lecteur borné d’Activité : pas de titre, seulement une empreinte du contexte
   ▼
segments actifs ── contextKey = FNV-1a(app | site | titre normalisé)
   │
   │  verdicts (work-classification.json) : contextKey → travail(tâche) / hors travail / indéterminé
   ▼
Day.applying(verdicts) → .work / .other / .unclassified + tâche
```

- **Contexte** (`GoalongWorkContext`) : app + site + titre de fenêtre normalisé (espaces
  réduits, compteurs « (3) » retirés, 160 caractères). Un événement sans fenêtre (frappe,
  clic) hérite du dernier contexte de la même app sur le même site.
- **Lecteur d’Activité** : ne garde plus de titre ; il ajoute seulement l’empreinte du
  contexte dans les métadonnées en mémoire. Les titres ne sont lus (projection
  `workContext`) que pour un classement ou une vérification explicite, et restent en mémoire.
- **Classement de l’app retiré** : `LocalClassifier` ne renvoie plus `isWork` ; les
  anciennes lignes du journal qui en portent un sont ignorées partout (Activité, ancien
  digest minute, tableau de bord hérité, bilan quotidien).
- **Tâches et focus** : une séquence de focus et une session de travail suivent une même
  tâche à travers les apps (tolérance de 2 min pour la session). Un détour inconnu de moins
  d’une minute entre deux moments de la même tâche lui est rattaché ; un verdict explicite
  (« hors travail ») n’est jamais écrasé.

## Agent

- États (`GoalongWorkClassification.states`, un seul endroit) : chaque contexte du jour est
  **classé** (travail / hors travail, par une règle de l’utilisateur ou par l’agent),
  **en attente** (avec une raison lisible : pas encore passé, pause, limite du jour, limite
  du compte proche, Codex occupé, consentement manquant…), **à préciser** (l’agent n’a pas su,
  ou le contexte est exclu de l’envoi) ou **trop court** (groupe de moins de 15 s sans règle).
- Règles de l’utilisateur : portée **contexte**, **app** ou **site**, appliquées sur le Mac
  avant tout envoi. Ordre : réponse sur le contexte > règle de site > règle d’app > agent.
  Les anciennes réponses (`byOwner`) restent des règles de contexte. Goalong ne crée jamais
  seul une règle d’app.
- Groupes : les titres sont normalisés (casse, suffixe « — App », nombres → #). Un seul
  contexte par groupe est envoyé ; sa réponse vaut pour tout le groupe et pour les membres
  vus plus tard (sans nouvel appel).
- Passage en arrière-plan : vérifié toutes les 15 min, seulement avec le consentement
  « Classer en arrière-plan » (décoché par défaut ; l’ancien réglage « automatique » ne
  compte pas). Au plus **2 appels par jour** : dès 40 groupes en attente, ou aux créneaux
  12 h 30 et 18 h 30 s’il reste quelque chose. Plafond **24 000 jetons par jour**, passage
  manuel compris. Rien en pause, pendant un bilan, quand Codex est occupé, ni quand le
  compte approche de sa limite (≥ 90 % d’une fenêtre, lue par `account/rateLimits/read`,
  sans inférence). Le passage manuel « Classer aujourd’hui » vit dans Réglages → Définition
  du travail ; Activité n’envoie plus rien à l’ouverture.
- Conditions : définition non vide, historique activé, consentement « Analyse ChatGPT »,
  compte ChatGPT connecté, pas de pause globale.
- Envoi : **un appel par passage**, 60 groupes au plus, les plus longs d’abord, réduit
  jusqu’à tenir dans les jetons restants du jour. Clés JSON courtes. Chaque contexte :
  app, site, titre (secrets masqués), minutes du groupe, 2 voisins (précédent, suivant) ;
  plus la définition, 20 tâches connues au plus et les **10 réponses de l’utilisateur les
  plus proches** (même site, puis même app).
- Filtre de confidentialité (`GoalongWorkSharingFilter`) : exclusions globales, puis
  sélection « Données pour ChatGPT » si elle est confirmée (apps autorisées, sites exclus,
  titres et sites autorisés, remplacements de noms). Un contexte filtré reste à classer.
  Les corrections envoyées comme exemples passent par le même filtre au moment de
  l’envoi : une correction sur un contexte exclu depuis n’est plus envoyée. Les
  remplacements de noms s’appliquent aussi à la définition, à la note du jour, aux tâches
  connues et aux tâches des voisins ; s’ils ne peuvent pas être appliqués, rien
  n’est envoyé. Les tâches renvoyées par l’agent peuvent donc porter le nom remplacé.
- Exécution : compte ChatGPT de Goalong (`codex app-server`, `CODEX_HOME` isolé), profil
  `goalong-site-analysis` (aucun outil, aucun réseau, aucun fichier), thread éphémère,
  `gpt-5.6-luna` / `low` (contrat de classement propre, vérifié par `model/list` ; le
  bilan quotidien garde `high`), instructions de base courtes, sortie JSON stricte. Les révisions des exclusions et des choix « Données pour
  ChatGPT » sont revérifiées avant chaque lot et juste avant l’envoi ; si l’une a changé,
  le classement s’arrête sans rien envoyer.
- Validation : même identifiant de requête (`r`), exactement un élément par contexte envoyé,
  aucun id inconnu ou dupliqué, verdict `w` / `o` / `u` ; sinon rien n’est enregistré.
  `u` devient *indéterminé* et
  peut être reposé sur un autre jour observé, avec au moins 5 minutes et moins de 3 tentatives automatiques. Un verdict de l’utilisateur n’est jamais reposé.

## Stockage

`~/Library/Application Support/LocalHistory/work-classification.json` (0600) :
révision de la définition, verdicts par empreinte de contexte (sans titre), `attempts` et `lastAskedDay` pour les tentatives automatiques, corrections
de l’utilisateur (avec leur libellé, pour servir d’exemples), règles d’app et de site,
verdicts par groupe, consentement d’arrière-plan (version), ancien réglage « automatique »
(gardé, sans effet). `work-classification-usage.json` (0600) : par jour (14 jours), appels,
appels d’arrière-plan, jetons (réels si Codex les publie par `thread/tokenUsage/updated`,
sinon estimés et marqués comme tels), part hebdomadaire du compte avant et après.
20 000 verdicts au plus (les plus anciens verdicts de l’agent sont retirés d’abord).

- Changer la définition efface les verdicts de l’agent ; les corrections restent.
- « Tout reclasser… » efface les verdicts de l’agent ; les corrections restent.
- « Effacer tout l’historique détaillé » efface aussi les verdicts et les corrections
  (avec leurs libellés) et arrête un classement en cours. Les effacements partiels
  (10 min, 1 h, 24 h) les gardent : une correction n’a pas de date.
- Renommer une tâche (ou lui donner le nom d’une autre pour les fusionner) s’applique à
  tous les contextes.
- Les anciens choix Travail / Hors travail par app (`activity-classification.json`) ne sont
  plus appliqués ; ils pré-remplissent une seule fois le brouillon de la définition. Le
  fichier n’est jamais modifié.

## Bilan quotidien

Le prompt du bilan reçoit la définition (masquée par les remplacements de noms) et la
consigne de juger le travail orienté vers un but à partir d’elle : une app ou un site ne
prouve jamais à lui seul du travail. La ligne « Work-classified time », issue de l’ancien
classement par app, n’est plus envoyée.

## Reposer un contexte indéterminé

Un contexte `unclear` automatique est admissible si le jour analysé lui apporte au moins
5 minutes, si aucune demande n’a été envoyée pour ce contexte ce jour-là et si moins de
3 tentatives automatiques ont eu lieu. Les anciens fichiers comptent comme une tentative,
avec `seen` pour le dernier jour demandé. Pour une nouvelle tentative, l’admission est
enregistrée avant l’envoi ; un échec de réponse compte aussi, pour éviter des requêtes
répétées sans limite. Une première demande qui échoue ne crée aucun verdict : le contexte
reste « à classer » et peut être renvoyé le jour même.

La demande peut inclure le dernier extrait visible de ce contexte (240 caractères), après
vérification du hash et redaction des secrets, seulement si une sélection « Données pour
ChatGPT » confirmée autorise le texte visible pour cette application et ce site. Exclusions
et remplacements de noms restent appliqués. La lecture sémantique est bornée à 32 768
lignes, 64 Mio et 20 secondes ; une lecture partielle ne fournit pas d’extrait. Aucun
extrait n’est persisté. La fonction de demande et l’agent acceptent une note du jour
optionnelle (280 caractères) ; son raccordement à la source de notes appartient au lot S.
