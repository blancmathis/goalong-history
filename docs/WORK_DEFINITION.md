# Mon travail — définition du travail et classement par agent

Goalong ne décide jamais qu’une application ou un site est productif. Une même app
sert au travail puis à autre chose (YouTube pour un cours puis pour se distraire,
Messages pour un client puis pour des amis). Le travail est donc défini par
l’utilisateur, avec ses mots, et appliqué par un agent à ce qu’il faisait vraiment.

## Ce que voit l’utilisateur

- **Mon travail** (barre latérale) : la définition (projets et objectifs, apps et sites
  et à quoi ils servent, contenus qui comptent comme travail, ce qui n’en est pas), l’état
  de l’agent, et « Vérifier et corriger » pour une journée.
- **Activité** : tuile Travail, carte **Tâches** (temps par projet, quelles que soient les
  apps), Concentration = plus longue session sur une même tâche, changements d’app « dont
  N sans quitter la tâche ». Sans définition, une carte invite à la rédiger.
- **Surveillance temps réel** : affiche un résumé de la même définition et renvoie vers
  Mon travail. Il n’existe qu’une définition (`JevWorkContextStore`, 800 octets).

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

- Déclenchement : à l’ouverture d’Activité pour les jours affichés (aujourd’hui au plus
  toutes les 15 min, un autre jour une fois par lancement, 30 min après un échec), après
  l’enregistrement d’une nouvelle définition, ou par « Classer aujourd’hui ». Aucune
  minuterie, rien pendant un bilan quotidien.
- Conditions : définition non vide, historique activé, consentement « Analyse ChatGPT »,
  compte ChatGPT connecté, pas de pause globale.
- Envoi : les contextes **sans verdict**, ou les contextes indéterminés admissibles à une nouvelle tentative, pour la définition actuelle, de 15 s ou
  plus, les plus longs d’abord, par lots de 250 (3 lots au plus par passage). Chaque
  contexte : nom de l’app, site, titre (secrets masqués), minutes ; plus la définition,
  les tâches déjà nommées, les corrections de l’utilisateur (40 au plus) et la chronologie
  du jour (contextes à classer par id, les autres par leur tâche connue).
- Filtre de confidentialité (`GoalongWorkSharingFilter`) : exclusions globales, puis
  sélection « Données pour ChatGPT » si elle est confirmée (apps autorisées, sites exclus,
  titres et sites autorisés, remplacements de noms). Un contexte filtré reste à classer.
- Exécution : compte ChatGPT de Goalong (`codex app-server`, `CODEX_HOME` isolé), profil
  `goalong-site-analysis` (aucun outil, aucun réseau, aucun fichier), thread éphémère,
  `gpt-5.6-luna` / `high`, sortie JSON stricte. La révision des exclusions est revérifiée
  avant l’envoi.
- Validation : même `request_id`, exactement un élément par contexte envoyé, aucun id
  inconnu ou dupliqué ; sinon rien n’est enregistré. « unknown » devient *indéterminé* et
  peut être reposé sur un autre jour observé, avec au moins 5 minutes et moins de 3 tentatives automatiques. Un verdict de l’utilisateur n’est jamais reposé.

## Stockage

`~/Library/Application Support/LocalHistory/work-classification.json` (0600) :
révision de la définition, verdicts par empreinte de contexte (sans titre), `attempts` et `lastAskedDay` pour les tentatives automatiques, corrections
de l’utilisateur (avec leur libellé, pour servir d’exemples), réglage « automatique ».
20 000 verdicts au plus (les plus anciens verdicts de l’agent sont retirés d’abord).

- Changer la définition efface les verdicts de l’agent ; les corrections restent.
- « Tout reclasser… » efface les verdicts de l’agent ; les corrections restent.
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
avec `seen` pour le dernier jour demandé. L’admission est enregistrée avant l’envoi ; un
échec de réponse compte aussi, pour éviter des requêtes répétées sans limite.

La demande peut inclure le dernier extrait visible de ce contexte (240 caractères), après
vérification du hash et redaction des secrets, seulement si une sélection « Données pour
ChatGPT » confirmée autorise le texte visible pour cette application et ce site. Exclusions
et remplacements de noms restent appliqués. La lecture sémantique est bornée à 32 768
lignes, 64 Mio et 20 secondes ; une lecture partielle ne fournit pas d’extrait. Aucun
extrait n’est persisté. La fonction de demande et l’agent acceptent une note du jour
optionnelle (280 caractères) ; son raccordement à la source de notes appartient au lot S.
