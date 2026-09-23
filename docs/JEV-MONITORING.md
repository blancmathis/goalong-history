# Jev : surveillance facultative et pauses minutées

## Commandes

Réglages → **Jev et pauses**. La capacité `jevMonitoring` est désactivée par
défaut et indépendante de Computer History, ChatGPT, de l’envoi au site et du
choix de collecte locale de texte. Son activation demande une confirmation
explicite de l’envoi à TypeSafe. L’utilisateur fournit sa propre clé API dans le
champ protégé ; aucun secret n’est inclus dans le code ou envoyé au site Goalong.
L’API TypeSafe peut être facturée selon son offre. Aucun appel n’est fait sans clé.

Le menu **Jev et pause minutée** permet une pause de 5, 10, 15 ou 30 minutes,
sa fin anticipée et la désactivation de Jev. Les réglages permettent aussi une
durée de 1 à 120 minutes. Le décompte persiste au redémarrage et à la veille.
Une pause de travail suspend Jev seulement : elle ne change aucun autre
consentement, ne réactive jamais l’enregistrement et ne remplace pas Pause globale.

## Fenêtres et avertissement

Un minuteur local traite des fenêtres distinctes de 15 secondes `[début, fin)`.
Seule cette fenêtre est envoyée, jamais une journée ni un arriéré. Une trace
exactement à la frontière appartient à la fenêtre suivante. Les changements
pertinents et les actions déjà autorisées alimentent un tampon en mémoire ; un
bref passage dans un fil doit rester présent même après le retour au code.

La question est : **la fenêtre contient-elle une activité de procrastination ?**
Pas « quel est son usage majoritaire ? ». Deux réponses positives exploitables
sur deux fenêtres adjacentes déclenchent une bannière non activante. Elle ne prend
pas le focus clavier, ne bloque pas le travail et offre Fermer, Pause et Désactiver.
Une seule alerte est émise pour une même série ; aucune escalade n’est ajoutée.
L’inactivité, une pause, un contexte protégé, une erreur ou un résultat indéterminé
interrompt la série. Une réponse tardive ou une requête annulée ne peut pas la
faire progresser. Après veille, retard important ou saut d’horloge, aucun arriéré
n’est envoyé.

Le classement est fourni uniquement par Jev `jev-1.13.0`, avec trois choix fermés :
`productive`, `procrastination`, `unknown`. Les mesures, règles de série et messages
restent dans Swift. La probabilité d’un choix n’est ni un pourcentage de temps
productif, ni une précision statistique validée sur les usages Goalong.

## Politique initiale et limites d’observation

La politique `strict-social-consumption-v1` répond au choix demandé : regarder des
vidéos ou consommer un fil social, même instructif, compte comme procrastination ;
composer un post ou produire un travail compte comme productif. Une recherche
sociale n’est pas assimilée à la rédaction d’un post. Lire une documentation n’est
pas automatiquement assimilé à un fil social.

Le classement reçoit les applications/domaines, titres disponibles et modes
observés (défilement, saisie, composition identifiable). Il ne reçoit jamais le
texte frappé ni une valeur de champ. Un champ de saisie social non identifié reste
ambigu. Une route `/compose/` et des labels de compositeur aident à distinguer la
création de contenu. Aucun label ne prouve qu’une publication a été achevée.

Jev ne reçoit ni capture d’écran, ni vidéo, ni son. Les titres et contrôles
dépendent des informations Accessibility exposées par le navigateur et des
permissions de collecte déjà activées. Un contrôle de lecture **Pause** explicite,
visible dans le contexte d’un site vidéo au premier plan, peut produire un signal
d’activité sans clic, par une lecture AX bornée ; un onglet simplement ouvert ne
suffit pas. Les lectures non exposées restent indétectables. Un contrôle manquant
ou du contenu défilant sous un titre inchangé ne deviennent pas magiquement visibles
pour le modèle. Il faut tester les navigateurs utilisés, en français et anglais.

## Données, budget et exclusions

`JevIngress` est un tampon de 512 échantillons maximum et 60 secondes de rétention
maximale, uniquement en mémoire. La requête ne sélectionne que les 15 secondes à
classer. Les doublons sont supprimés, les titres raccourcis, mais les modes distincts
ne sont pas remplacés par le seul dernier contexte. Une fenêtre trop complexe
pour tenir dans le budget est ignorée et reste indéterminée, sans alerte.

**Le JSON complet est borné à 800 octets UTF-8**, instructions et critères inclus.
Ce n’est pas une estimation `caractères/4`. L’API ne publie pas le tokenizer et son
éventuel encadrement interne : ce plafond conservateur ne constitue donc pas une
preuve du nombre exact de tokens côté serveur. Chaque réponse doit annoncer moins
de 1 000 tokens d’entrée. Une réponse dépassant ce seuil ouvre un coupe-circuit ;
aucun nouveau contexte n’est envoyé avant intervention de l’utilisateur. Le compteur
réel du dernier appel est visible. Il faut valider ce contrat avec une clé réelle
avant de promettre une garantie exacte sur le comptage du fournisseur.

Les chemins complets et paramètres d’URL ne sont pas transmis. Les titres sont
bornés et filtrés pour les URL, emails et secrets explicitement étiquetés ; ce
filtrage ne garantit pas d’anonymiser tout texte. Le contexte peut rester personnel.
Un très court extrait de texte visible est facultatif, avec un accord distant
supplémentaire **et** le consentement local préexistant au texte riche. Aucun nouvel
accès n’est activé pour l’obtenir.

Fenêtres privées, saisie sécurisée, exclusions et pauses restent prioritaires.
La navigation privée n’est jamais transmise, même lorsque l’utilisateur a autorisé
séparément son enregistrement local. Les changements de politique ou de pause
invalident les résultats en cours. Un envoi déjà commencé peut avoir atteint le
prestataire ; l’annulation ne peut pas le rappeler.

## Transport et stockage

`JevTransport` est la seule émission Jev : POST HTTPS vers
`https://api.typesafe.ai/v1/systemone`, session éphémère, sans cookie, cache disque,
redirection, commande, outil ni requête de rattrapage. Réponse maximum 64 Kio,
délai ressource 12 secondes. Les erreurs 401/403 suspendent l’usage jusqu’à
correction ; 429 respecte `Retry-After` borné ; les autres erreurs temporisent et
remettent la série à zéro. Aucun message fournisseur arbitraire ne devient une
alerte utilisateur.

La clé et la minuterie sont dans le répertoire local `jev/` (0700), fichiers
`api-key` et `break.json` (0600), accès sans lien symbolique. Aucun prompt ni corps
de réponse n’est journalisé. Un aperçu de la dernière requête, sans clé, et les
120 derniers résultats de fenêtres restent en mémoire seulement. Ils ne constituent
pas une frise journalière persistante et ne réécrivent jamais les journaux scellés.
Le manifeste de sécurité déclare cette nouvelle émission distincte. Les conditions
de traitement/rétention côté TypeSafe restent celles de son service : l’éphémérité
de la session réseau locale ne constitue pas une promesse de rétention zéro distante.

## Validation

```
swift test --filter Jev
python3 scripts/test_site_submission_policy.py
./scripts/verify_source_security.sh
```

Les tests utilisent des horloges explicites, des fixtures de navigateur, des
réponses HTTP synthétiques et des dossiers temporaires, sans clé ni contexte réel.
Ils couvrent notamment les doubles fenêtres, pause/reprise, Unicode et budget,
les résultats ambigus, les champs de composition/recherche, les exclusions privées,
le stockage protégé et les erreurs/cancellations réseau. Un test en conditions
réelles exige une clé TypeSafe, un Mac et ses permissions Accessibility. Les tests
synthétiques ne prouvent pas la précision sémantique réelle de Jev.
