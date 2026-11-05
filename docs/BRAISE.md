# Écran rouge (moteur Braise)

Braise est porté depuis les sources locales `Sources/Braise` et `Sources/BraiseCore`
de l’app Braise 1.0.1, conservées sans modification. Le moteur d’horaires et ses tests
sont dans `Features/Braise`. Le contrôleur macOS, le gamma, le menu et la page
sont dans `Sources/LocalHistoryApp/Braise`. L’interface s’appelle **Écran rouge**.

## Activer et utiliser

Aucun module à activer. La ligne **Écran rouge** est dans le panneau Goalong (clic
gauche) et dans le menu Goalong (clic droit) : un interrupteur et un curseur d’intensité
qui agit pendant le glissement. Le menu ajoute un sous-menu **Intensité** (25–100 %),
**Suivre mes horaires**, **Rétablir les couleurs** et **Plages et réglages…**, qui ouvre
**Garde-fous › Écran rouge**. Il n’y a qu’une icône Goalong : Braise n’a plus la sienne.

Braise n’est plus dans **Réglages › Modules** : sans activation préalable, un interrupteur
de module doublerait celui du menu. La clé `goalong.module.braise.enabled` d’une ancienne
version est lue une fois au démarrage (le contrôleur démarre, couleurs inchangées), puis
retirée.

## Garde-fous et plages protégées (T-048 B2)

La section **Garde-fous** de la barre latérale (⌘5) contient **Blocages** et **Écran
rouge**. Les **plages protégées** de l’écran rouge (« tous les jours de 22 h à 7 h, rouge
à 80 % », jours au choix) utilisent le modèle des blocages : `BlockProgram` et
`BlockProgramRange` (jours ISO, lundi = 1), le même éditeur de plage et le même verrou
(Libre / Difficile / Mot de passe / Verrouillé, voir `docs/BLOCKING.md` « Range lock »).
Code : `RedScreenProgram.swift` (modèle et règles pures), `BraiseController.swift`.

- **Manuel et plages se cumulent** : l’intensité la plus forte gagne. Couper le manuel ne
  coupe jamais une plage en cours.
- **Pendant une plage protégée**, tout affaiblissement suit la règle d’un blocage actif :
  pas de minute perdue, pas de verrou abaissé, pas d’intensité qui baisse, « Suivre mes
  horaires » reste coché. « Difficile » demande de taper le texte, « Mot de passe » le mot
  de passe des blocages ; sans mot de passe, la plage compte comme verrouillée. Renforcer
  est toujours libre. Les commandes de l’écran rouge (menu, panneau, ⌃ ⌥ ⌘ R, CLI `off`)
  sont alors des affaiblissements : « Rétablir les couleurs » est grisé. Hors plage, elles
  agissent tout de suite.
- Une plage en cours est **tenue jusqu’à sa fin** sur une échéance monotone : avancer
  l’horloge, changer de fuseau ou modifier le fichier ne l’abrège pas. Au changement
  d’heure, la fin prend la seconde occurrence de l’heure répétée.
- La **luminosité** est un confort : jamais verrouillée.
- Une **panne technique** (écran incompatible, gamma refusé, gardien perdu) rend les
  couleurs tout de suite, même pendant une plage verrouillée.
- 32 plages au maximum. Une plage qui passe minuit compte pour le jour où elle commence.

Stockage : `Braise/ranges.json` (mêmes protections que `settings.json`). À la première
lecture, chaque horaire Braise devient une plage : jours convertis (Braise 1 = dimanche →
ISO 7), fin 00:00 → 24:00, horaire désactivé ou invalide gardé comme plage éteinte,
intensité reprise, mode Auto → « Suivre mes horaires ». `settings.json` n’est pas modifié :
une version plus ancienne de Goalong retrouve ses horaires. Un `ranges.json` abîmé est mis
de côté puis reconstruit depuis `settings.json`. Tests : `RedScreenRangesTests`.

Écrans : l’origine gamma de chaque écran est gardée par clé stable (fabricant, modèle,
numéro de série). Un écran rebranché pendant le rouge retrouve sa vraie origine. Sans clé,
une table lue déjà rouge déclenche une remise ColorSync puis une relecture de toutes les
origines. Tests : `RedScreenGammaOriginTests` (faux pilote).

- Intensité 0–100 %, luminosité logicielle 20–100 %. À intensité 100 %, les canaux
  vert et bleu de la table gamma sont à zéro. La luminosité matérielle ne change pas.
- Ajout, modification, suppression et activation des plages sont dans
  **Garde-fous › Écran rouge**.
- **⌃ ⌥ ⌘ R** restaure immédiatement les couleurs hors plage protégée.
  Une collision de raccourci est signalée ; le menu et le panneau restent disponibles.
- Le réglage de démarrage à la connexion concerne **toute l’app Goalong** et utilise
  son élément de connexion existant. Aucune inscription automatique lors de l’activation.

Les écrans externes non miroirs sont inclus. Au réveil, au changement d’écran,
d’heure ou de fuseau, l’état est recalculé. Braise ne réveille pas le Mac. Le HDR,
la dalle et les autres apps de couleur peuvent modifier le résultat : aucune garantie
de zéro lumière bleue physiquement émise.

## Cycle de vie et restauration

L’écran rouge est **éteint par défaut**. Jamais utilisé : aucun contrôleur, timer,
observateur, raccourci, fichier ouvert, processus ni appel gamma. Le contrôleur naît au
premier allumage. `goalong.redScreen.armed` (mode autre que Désactivé) et
`goalong.redScreen.intensity` survivent au redémarrage ; armé, le contrôleur redémarre
avec Goalong. Rouge éteint, un écran branché ou débranché ne provoque aucun appel gamma ;
rouge allumé, le nouvel écran passe au rouge lui aussi.

Le pilote utilise les API publiques CoreGraphics de tables gamma. Il lit les tables
originales, les sauvegarde et démarre un gardien avant de modifier les écrans. Ce gardien
est le même exécutable, uniquement avec `--braise-guardian` et un chemin de récupération
local contrôlé. Son entrée sort avant tout lancement, migration ou collecte Goalong.
Un acquittement confirme son démarrage. Il dort sur un pipe ; sa fermeture, y compris
après SIGKILL du parent, restaure les couleurs. Aucun polling dans ce sous-processus.
Chaque activation a un fichier unique : un ancien gardien ne lit pas celui de la suivante.

Arrêt du rouge et fermeture normale de Goalong : restauration immédiate, annulation des
timers et sauvegardes différées, retrait des observateurs et du raccourci. Le gardien est
désarmé. La fermeture garde le réglage ; au relancement, les tables laissées par un crash
sont restaurées avant toute lecture, puis le rouge revient si le réglage est allumé. Les fichiers de récupération résiduels sont traités
à l’activation suivante. Un écran incompatible, un filtre rejeté ou un gardien indisponible
laisse le filtre désactivé et expose une erreur française.

## Réglages et migration

Goalong conserve les réglages dans
`~/Library/Application Support/LocalHistory/Braise/settings.json` (dossier 0700,
fichier 0600, remplacement atomique). Au **premier allumage uniquement**, si ce fichier
n’existe pas, il importe `~/Library/Application Support/Braise/settings.json` : mode,
intensité, luminosité, horaires, identifiants et pause. L’original reste intact ;
`./uninstall.sh --purge-data` le supprime avec le reste des données.
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

Jours en entrée de `schedule add` : 1=dimanche, 2=lundi … 7=samedi (syntaxe Braise).
`schedule list` répond en jours ISO (1=lundi … 7=dimanche). Les commandes `schedule`
agissent sur les plages et suivent les mêmes règles de verrou. `show` ouvre Garde-fous › Écran rouge.
`off` restaure les couleurs en gardant le contrôleur chargé. `quit` est un alias de `disable` :
il arrête **l’écran rouge seulement**, en gardant Goalong ouverte. `on` et `enable`
démarrent le contrôleur au besoin. `status` indique `enabled:false` sans créer de
contrôleur. `probe` renvoie `[]` tant que le contrôleur n’existe pas. `login` configure le démarrage de Goalong.

## Frontières et vérification

Aucune sortie réseau, nouvelle permission, capture d’écran, texte de clavier, événement
d’entrée global enregistré, overlay, composant privilégié ni changement de luminosité
matérielle. Le raccourci utilise Carbon `RegisterEventHotKey`, pas un event tap.
Le gamma et le lancement du gardien sont limités au seul pilote audité ; les inventaires
de sécurité et l’allowlist des sources de diagnostic incluent Braise.

Contrôles : `swift build`, `swift test`, `scripts/verify_source_security.sh`, les audits
de dépendance, Jev et envoi au site appelés par les scripts du dépôt. Les tests utilisent
des dossiers temporaires et un pilote gamma factice ; ils ne modifient pas les écrans.
`RedScreenGuaranteeTests` prouve avec de faux écrans le retour des couleurs à l’arrêt,
à la fermeture et après un crash (gardien puis relancement), le branchement et le
débranchement d’écran, l’absence d’appel gamma rouge éteint et la persistance du réglage.
Construire le vrai pilote (`CoreGraphicsDisplays`) sous XCTest hors CI
(`GITHUB_ACTIONS=true`) le laisse inerte et fait échouer le test en cours.
Le moteur d’horaires conserve les tests Braise, notamment chevauchements et changements
d’heure. Les rendus natifs utilisent les mêmes vues avec un pilote factice :

```sh
GOALONG_BRAISE_SNAPSHOTS=/tmp/goalong-braise-renders make check FILTER=BraisePageRenderingTests
GOALONG_DESIGN_AUDIT_ONLY=settings-modules scripts/verify_design_audit.sh /tmp/goalong-braise-settings
```

Ces contrôles ne constituent pas un essai physique du gamma, du HDR, d’un crash,
du raccourci global ou de plusieurs écrans. Aucun lancement de Goalong installée
n’est nécessaire pour les exécuter. L’essai réel reste à faire par le propriétaire
avant fusion. Livraison en PR brouillon ; aucune fusion ou release dans ce portage.
