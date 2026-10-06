# Braise — filtre rouge optionnel

Braise est porté depuis les sources locales `Sources/Braise` et `Sources/BraiseCore`
de l’app Braise 1.0.1, conservées sans modification. Le moteur d’horaires et ses tests
sont dans `Features/Braise`. Le contrôleur macOS, le gamma, la barre de menu et la page
sont dans `Sources/LocalHistoryApp/Braise`. Ce module suit la même activation volontaire
qu’Ambiance et Concentration.

## Activer et utiliser

Dans **Réglages › Modules**, activez **Braise**, puis cliquez sur **Ouvrir**.
Son entrée apparaît dans la barre latérale et son icône dans la barre de menu.
Un clic ouvre le panneau ; le clic droit propose les modes et le retour aux couleurs
naturelles. Aucun panneau ne s’ouvre au démarrage.

- **Auto** suit l’union des horaires activés ; les plages voisines ou superposées
  ne font pas clignoter les couleurs. Les jours choisis sont ceux du début : lundi
  22:00–08:00 finit mardi matin. Les changements d’heure utilisent l’heure locale.
- **Activé** conserve le filtre sans heure de fin ; **Désactivé** restaure les couleurs.
- Intensité 0–100 %, luminosité logicielle 20–100 %. À intensité 100 %, les canaux
  vert et bleu de la table gamma sont à zéro. La luminosité matérielle ne change pas.
- **Pause 15 min**, **Reprendre**, ajout, modification, suppression et activation
  des horaires (32 maximum) sont accessibles dans le panneau et la page.
- **⌃ ⌥ ⌘ R** restaure immédiatement les couleurs et passe en mode Désactivé.
  Une collision de raccourci est signalée ; le bouton et le clic droit restent disponibles.
- Le réglage de démarrage à la connexion concerne **toute l’app Goalong** et utilise
  son élément de connexion existant. Aucune inscription automatique lors de l’activation.

Les écrans externes non miroirs sont inclus. Au réveil, au changement d’écran,
d’heure ou de fuseau, l’état est recalculé. Braise ne réveille pas le Mac. Le HDR,
la dalle et les autres apps de couleur peuvent modifier le résultat : aucune garantie
de zéro lumière bleue physiquement émise.

## Cycle de vie et restauration

Le module est **désactivé par défaut**, clé `goalong.module.braise.enabled`.
Éteint : aucun contrôleur, timer, observateur, raccourci, menu, fichier ouvert ou processus.
Le gate `BraiseRuntime` ne consulte son dossier qu’après activation explicite (ou au
démarrage suivant, si le membre l’a laissé activé).

Le pilote utilise les API publiques CoreGraphics de tables gamma. Il lit les tables
originales, les sauvegarde et démarre un gardien avant de modifier les écrans. Ce gardien
est le même exécutable, uniquement avec `--braise-guardian` et un chemin de récupération
local contrôlé. Son entrée sort avant tout lancement, migration ou collecte Goalong.
Un acquittement confirme son démarrage. Il dort sur un pipe ; sa fermeture, y compris
après SIGKILL du parent, restaure les couleurs. Aucun polling dans ce sous-processus.
Chaque activation a un fichier unique : un ancien gardien ne lit pas celui de la suivante.

Désactivation du module et fermeture normale de Goalong : restauration immédiate,
annulation des timers et sauvegardes différées, retrait des observateurs, du raccourci
et du menu. Le gardien est désarmé. Les fichiers de récupération résiduels sont traités
à l’activation suivante. Un écran incompatible, un filtre rejeté ou un gardien indisponible
laisse le filtre désactivé et expose une erreur française.

## Réglages et migration

Goalong conserve les réglages dans
`~/Library/Application Support/LocalHistory/Braise/settings.json` (dossier 0700,
fichier 0600, remplacement atomique). Au **premier allumage uniquement**, si ce fichier
n’existe pas, il importe `~/Library/Application Support/Braise/settings.json` : mode,
intensité, luminosité, horaires, identifiants et pause. L’original reste intact.
Sans réglages d’origine, le filtre démarre Désactivé et une plage quotidienne 22:00–08:00
est proposée. Un fichier illisible ou invalide empêche le démarrage, sans l’écraser.

Lecture limitée à 64 Kio, propriétaire UID courant, fichier régulier, liens symboliques
refusés ; valeurs bornées et identifiants d’horaires dédoublonnés. Les tables de récupération
ont aussi une taille limitée et des tableaux validés. Les préférences restent conservées
lorsque le module est éteint. L’élément de connexion Braise n’est pas migré : seule une
action explicite peut modifier celui de Goalong.

## CLI

Les commandes parlent au socket local Goalong existant, accessible au même UID.
La syntaxe est vérifiée dans le client **et** dans l’app avant tout effet. Réponses JSON,
erreurs sur stderr et code de sortie non nul. L’app doit être ouverte ; aucun lancement
automatique et aucune notification distribuée.

```text
goalong braise enable | disable
goalong braise status | probe | show
goalong braise on | off | auto
goalong braise pause | resume
goalong braise intensity 0...100
goalong braise brightness 20...100
goalong braise schedule list
goalong braise schedule add 2,3,4,5,6 22:00 08:00
goalong braise schedule remove UUID
goalong braise schedule enable UUID | disable UUID
goalong braise login on | off
goalong braise quit
```

Jours : 1=dimanche, 2=lundi … 7=samedi. `show` ouvre le panneau de barre de menu.
`off` restaure les couleurs en gardant le module chargé. `quit` est un alias de `disable` :
il arrête **Braise seulement**, en gardant Goalong ouverte. `enable` est l’allumage
explicite du module ; `on` ne contourne pas un module désactivé. `status` indique
`enabled:false` sans créer de contrôleur. `probe` lit les tables des écrans, uniquement
si le module est activé. `login` configure le démarrage de Goalong.

## Frontières et vérification

Aucune sortie réseau, nouvelle permission, capture d’écran, texte de clavier, événement
d’entrée global enregistré, overlay, composant privilégié ni changement de luminosité
matérielle. Le raccourci utilise Carbon `RegisterEventHotKey`, pas un event tap.
Le gamma et le lancement du gardien sont limités au seul pilote audité ; les inventaires
de sécurité et l’allowlist des sources de diagnostic incluent Braise.

Contrôles : `swift build`, `swift test`, `scripts/verify_source_security.sh`, les audits
de dépendance, Jev et envoi au site appelés par les scripts du dépôt. Les tests utilisent
des dossiers temporaires et un pilote gamma factice ; ils ne modifient pas les écrans.
Le moteur d’horaires conserve les tests Braise, notamment chevauchements et changements
d’heure. Les rendus natifs utilisent les mêmes vues avec un pilote factice :

```sh
GOALONG_BRAISE_SNAPSHOTS=/tmp/goalong-braise-renders swift test --filter BraisePageRenderingTests
GOALONG_DESIGN_AUDIT_ONLY=settings-modules scripts/verify_design_audit.sh /tmp/goalong-braise-settings
```

Ces contrôles ne constituent pas un essai physique du gamma, du HDR, d’un crash,
du raccourci global ou de plusieurs écrans. Aucun lancement de Goalong installée
n’est nécessaire pour les exécuter. L’essai réel reste à faire par le propriétaire
avant fusion. Livraison en PR brouillon ; aucune fusion ou release dans ce portage.
