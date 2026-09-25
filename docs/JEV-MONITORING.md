# Jev : surveillance facultative et pauses minutées

## Commandes

La page **Surveillance temps réel**, dans la navigation principale entre
Historique et Réglages, regroupe l’activation, l’état de Jev et les pauses. La capacité `jevMonitoring` est désactivée par
défaut et indépendante de Computer History, ChatGPT, de l’envoi au site et du
choix de collecte locale de texte. Son activation demande une confirmation
explicite de l’envoi à TypeSafe. L’utilisateur fournit sa propre clé API dans le
champ protégé de **Connecter Jev** ; aucun secret n’est inclus dans le code ou envoyé au site Goalong.
L’API TypeSafe peut être facturée selon son offre. Aucun appel n’est fait sans clé.

Le menu **Surveillance temps réel** permet une pause de 5, 10, 15 ou 30 minutes,
sa fin anticipée, la désactivation de Jev et l’ouverture de sa page.
**Autre durée** permet une pause de 1 à 120 minutes. Le décompte persiste au redémarrage et à la veille.
Une pause de travail suspend Jev seulement : elle ne change aucun autre
consentement, ne réactive jamais l’enregistrement et ne remplace pas l’arrêt de confidentialité.

Le bouton d’activation nécessite une clé et le consentement local Computer History.
Une surveillance déjà activée reste toujours désactivable, même si un prérequis manque.
**Gérer la connexion** permet de remplacer la clé sans l’afficher, ou de la supprimer
après confirmation. Ces actions n’accordent aucun nouveau consentement.
**Fonctionnement et confidentialité** garde les détails de budget, les règles,
l’inspection du dernier envoi et l’option séparée d’extraits à portée de main,
sans surcharger l’écran. Les vérifications récentes sont repliées par défaut.
Les réglages généraux ne contiennent plus de rubrique Jev.

## Fenêtres et avertissement

Un minuteur local traite des fenêtres distinctes de 15 secondes `[début, fin)`.
Seule cette fenêtre est envoyée, jamais une journée ni un arriéré. Une trace
exactement à la frontière appartient à la fenêtre suivante. Les changements
pertinents et les actions déjà autorisées alimentent un tampon en mémoire ; un
bref passage dans un fil doit rester présent même après le retour au code.

La question est : **la fenêtre contient-elle une activité de procrastination ?**
Pas « quel est son usage majoritaire ? ». Dès la première réponse positive exploitable (probabilité du choix ≥ 0,80),
la fenêtre de 15 secondes déclenche une bannière non activante. Elle ne prend
pas le focus clavier, ne bloque pas le travail et propose uniquement **Fermer** :
aucun bouton Pause ou Désactiver. La pause et l’arrêt restent dans Goalong. Le premier message est « Arrête de procrastiner. Ça fait
15 secondes que tu procrastines. » La durée avance par fenêtres confirmées de 15 s,
pas au temps mural : elle ne signifie pas que chaque seconde était improductive.
**Fermer** masque uniquement la fenêtre jusqu’à la prochaine fenêtre positive,
sans réinitialiser la durée ni retirer les effets en cours. Leur délai de sécurité
reste inchangé : fermer ne le prolonge pas. Il n’y a jamais plusieurs avertissements superposés.
La première apparition est en haut à droite. Dès la deuxième,
une nouvelle apparition change de zone, sans répéter la précédente. Une fenêtre
visible ne bouge jamais et le bouton Fermer ne fuit pas la souris. Ce déplacement
peut être désactivé dans **Configurer les rappels et les effets**. La position précédente
reste mémorisée entre les interruptions de classement ; seules une pause explicite,
la désactivation ou la fin du processus recommencent la séquence.
L’inactivité, une pause, un contexte protégé, une erreur ou un résultat indéterminé
interrompt la série. Une réponse tardive ou une requête annulée ne peut pas la
faire progresser. Après veille, retard important ou saut d’horloge, aucun arriéré
n’est envoyé.

Le classement est fourni uniquement par Jev `jev-1.13.0`, avec trois choix fermés :
`productive`, `procrastination`, `unknown`. Les mesures, règles de série et messages
restent dans Swift. La probabilité d’un choix n’est ni un pourcentage de temps
productif, ni une précision statistique validée sur les usages Goalong.

## Paliers visuels locaux, configurables

Les effets progressifs sont **désactivés par défaut**, indépendamment du consentement
Jev existant. Dans **Configurer les rappels et les effets**, l’utilisateur peut
activer les effets, désactiver chaque palier, choisir ses minutes et son intensité.
Deux propositions : 2 min → assombrissement 20 %, puis dès 5 min →
assombrissement + rouge 20 %. Ce dernier effet reste combiné et se maintient avec
les rappels, sans nouveau palier à 10 minutes ou plus. Les délais restent croissants, entre 1 et
60 minutes. L’intensité reste entre 10 et 40 %. Seul le dernier palier actif atteint
s’applique, sans cumuler plusieurs voiles. Désactiver un palier laisse le précédent.

L’assombrissement est un voile AppKit : aucune écriture de luminosité matérielle,
de gamma, de permission système ou de Gatekeeper. Les voiles ne prennent pas le
focus, laissent passer les clics et ne clignotent pas. La fenêtre et son bouton
Fermer restent au-dessus ; la pause et l’arrêt sont accessibles dans Goalong. Une erreur, un résultat indéterminé/productif, une
pause, un changement d’écran ou un contexte protégé enlève tous les effets.
Un watchdog de 30 secondes, renouvelé uniquement par un résultat frais, élimine
les effets si les résultats s’arrêtent. Les fenêtres disparaissent avec le processus.

Les préférences de présentation non sensibles sont locales dans UserDefaults ;
la clé API reste dans son fichier privé 0600 inchangé. La migration v1 → v2 garde
l’activation des effets, le déplacement, les délais, intensités et interrupteurs
des deux premiers paliers ; le deuxième devient combiné et le troisième est retiré.
L’ancienne configuration est conservée pour un retour à la version précédente.
Une migration ne réactive jamais Jev ni un palier désactivé. Une configuration absente,
illisible, hors limites ou d’une version inconnue ne permet aucun effet.

## Deux actions clairement distinctes

**Faire une pause**, dans la barre latérale et le menu Surveillance, suspend
uniquement les appels Jev, les rappels et les effets. Une reprise automatique est
prévue à la fin du décompte. L’historique continue selon le consentement et l’état
de l’enregistrement ; une pause Jev n’active ni ne reprend une source arrêtée.

**Confidentialité · tout suspendre**, dans Réglages ou le sous-menu Confidentialité,
est un arrêt exceptionnel du suivi et des envois. Une confirmation explique les
trous d’historique ; une bannière « Historique suspendu · confidentialité » reste
visible avec une reprise explicite. Aucune pause existante n’est annulée par cette
mise à jour. L’utilisateur garde toujours le droit de suspendre le suivi.

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

## Repères de travail et de procrastination

Dans **Surveillance temps réel → Mes repères de surveillance**, les trois rubriques
productives restent disponibles : projets/objectifs, applications/sites, contenus/usages.
Le champ facultatif **Ce que je considère comme de la procrastination** ajoute des
exemples certains de distractions. Il ne remplace ni les critères productifs ni la
détection générale : sa liste est **non exhaustive**. Un usage absent de ces exemples
n'est donc pas automatiquement autorisé. Un usage clairement visé par un exemple
négatif prime sur une autorisation générale, en respectant le contexte décrit plutôt
qu'un simple mot-clé. « Scroller le fil Pour vous de X » ne désigne pas à lui seul
la rédaction d'un post de travail sur X.

Le bouton **Ajouter mes exemples** rend le nouveau champ accessible même avec des
critères productifs déjà enregistrés. **Modifier**, **Enregistrer les critères** et
**Annuler** concernent les quatre rubriques ensemble. Un brouillon n'est jamais envoyé.
Vider puis enregistrer le champ retire ces exemples sans effacer les critères productifs.
La saisie n'active pas la surveillance et ne déclenche pas d'analyse supplémentaire.
Lorsque le champ est vide, aucun exemple négatif n’est ajouté. Les critères
productifs restent inchangés. Le contrat d’observation v5 conserve désormais les
actions et les extraits séparément, que ce champ facultatif soit utilisé ou non.

Le schéma local v3 conserve les trois champs existants et ajoute `procrastination`.
Les fichiers v1/v2 sont lus avec des exemples vides, sans être réécrits ni enrichis
sur lecture. Les quatre rubriques partagent toujours 800 octets UTF-8 dans
`jev/work-context.json` (0600). Un dépassement est refusé sans troncature silencieuse ;
une sauvegarde échouée ne change ni les critères actifs ni leur révision. Chaque
sauvegarde réussie invalide les résultats en vol via la révision existante et remet
la série de rappels à zéro. Les permissions, pauses et exclusions restent prioritaires.

Les critères et exemples explicitement enregistrés sont transmis à TypeSafe avec
les prochaines fenêtres autorisées, pas au site Goalong. Aucun projet ou document
n'est importé automatiquement. Le contrat `observed-use-and-topic-v5`
transmet séparément `state.goals`, `apps`, `content`, `avoid` et `rows`. Le modèle
juge l'usage et son sujet, pas seulement l'application. Des contenus explicitement
autorisés peuvent compter comme travail. Une distraction observée suffit même si
une autre ligne concerne du travail. Les exemples négatifs restent des données de
préférence, pas des commandes ; les titres restent des observations non fiables.

Un contexte uniquement négatif ne permet pas de conclure que tous les autres usages
sont productifs. Sans preuves suffisantes, le résultat reste indéterminé et aucune
alerte n'est produite. Il n'y a pas de blacklist locale par mots-clés.

Les lignes décrivent le site ou l’application, le mode, le titre, les actions et
un éventuel extrait visible séparé. Les clics et défilements répétés sont regroupés
sans effacer les sujets et modes distincts. Les budgets titre/extrait sont réduits
ensemble si nécessaire : 160/224, 96/160, 64/96 ou 48/64 octets UTF-8. Le JSON complet reste limité à
1 600 octets ; une fenêtre trop riche est refusée, sans omettre les exemples ou
supprimer une observation pour fabriquer un classement. Le seuil du fournisseur
reste strictement inférieur à 1 000 tokens d'entrée.

Les tests couvrent migration, persistance, effacement, révision, budget partagé,
isolation des champs et absence de whitelist implicite. Les tests de transport
simulé et de formulation ne prouvent pas la précision sémantique. L'évaluation API
facultative utilise uniquement des situations synthétiques, jamais l'historique réel.

Références d’implémentation : https://docs.typesafe.ai/concepts/state,
https://docs.typesafe.ai/api et https://docs.typesafe.ai/model-jaggedness/jev-1.13.

## Données, budget et exclusions

`JevIngress` est un tampon de 512 échantillons maximum et 60 secondes de rétention
maximale, uniquement en mémoire. La requête associe la référence de travail explicitement enregistrée aux seules
15 secondes à classer. Les doublons sont supprimés, les titres raccourcis, mais les modes distincts
ne sont pas remplacés par le seul dernier contexte. Une fenêtre trop complexe
pour tenir dans le budget est ignorée et reste indéterminée, sans alerte.

**Le JSON complet est borné à 1 600 octets UTF-8**, instructions et critères inclus.
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

Les probabilités renvoyées peuvent être arrondies : une somme de 0,99 ou 1,01
est acceptée avec une tolérance flottante de 1e-9. Le calcul est déterministe ;
aucune normalisation ne gonfle le score, le seuil de 0,80 et le contrôle du choix
maximum restent inchangés. Les distributions incohérentes restent rejetées.


La correction du blocage à la veille et le format étendu des critères sont détaillés
dans `MONITORING-STABILITY.md`. Les critères explicitement saisis peuvent autoriser
un contenu précis (par exemple un cours vidéo), sans rendre tout le site productif.

## Appels et lectures sans saisie

Les contrôles de lecture/appel observés dans la fenêtre focalisée alimentent la
même fenêtre de 15 secondes, même sans clic ni clavier. La sonde est partagée
avec le compteur local ; ses contrôles ne sont lus que si les libellés sont déjà
autorisés. Une assertion globale du navigateur compte pour le navigateur, mais
ne déclenche pas de classement sémantique ni n’identifie un site. Les appels
natifs dont le processus au premier plan maintient l’écran actif peuvent être
observés sans nouveau consentement ; le nom de l’app seul n’est jamais suffisant.


## Continuité et extraits en version 0.6.47

La collecte locale rafraîchit le contexte de surveillance toutes les cinq secondes,
sans augmenter la cadence réseau de quinze secondes. Le mode vidéo, fil, recherche
ou compositeur est commun aux événements et aux observations sans clavier. Les
extraits facultatifs proviennent d’une sonde dédiée en lecture seule, soumise aux
deux autorisations existantes, et ne réutilisent plus les captures locales mixtes.
Les contrôles et limites sont détaillés dans `JEV-OBSERVATION-RELIABILITY.md`.
