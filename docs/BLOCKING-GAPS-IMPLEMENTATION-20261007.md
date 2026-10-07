# Blocage — API moteur livrée (2026-10-07)

Worktree : `/Users/mathisblanc/Developer/goalong-blocage-20261007`, branche
`design/blocage-20261007`. Implémentation non visuelle de
`BLOCKING-GAPS-20261007.md` A/B/C/D. L’UI SwiftUI reste à réaliser par Claude ;
les quatre switches de `BlockingPage.swift` traitent provisoirement `.password`
comme `.locked`, avec TODO.

## Signatures pour l’UI

Toutes ces API appartiennent à `@MainActor BlockingController`.

```swift
@Published private(set) var hasPassword: Bool
@Published private(set) var quitRequiresPassword: Bool
@Published private(set) var scheduledBlocks: [BlockSession]

@discardableResult
func setPassword(_ password: String) -> Bool
@discardableResult
func changePassword(old: String, new: String) -> BlockingPasswordResult
@discardableResult
func removePassword(old: String) -> BlockingPasswordResult
@discardableResult
func unlockWithPassword(_ password: String, blockID: UUID) -> BlockingPasswordResult

@discardableResult
func schedule(listIDs: [UUID], start: Date, end: Date, lock: BlockLock) -> UUID?
@discardableResult
func cancelScheduled(id: UUID, typed: String? = nil,
                     password: String? = nil) -> BlockingPasswordResult
func stop(_ id: UUID, typed: String? = nil, password: String? = nil)
func takeBreak(listID: UUID, password: String? = nil)

@discardableResult
func authorizeQuit(password: String) -> BlockingPasswordResult
func editCheck(_ next: BlockList) -> BlockingEditCheck
```

`schedule` renvoie l’ID enregistré ou nil avec `error`. Le début doit être
présent/futur et la fin après le début ; utiliser `start(listIDs:until:lock:)`
pour démarrer immédiatement. `scheduledBlocks` expose les sessions futures,
triées par début. Une session devient active à `start <= now < end` ; aucune
restriction sur le contenu de ses listes avant le début.

`unlockWithPassword` **arrête la session / annule la session future / saute
l’occurrence de programme ciblée**. Il ne donne aucune autorisation générale
pour modifier les listes ni pour arrêter un autre bloc. `cancelScheduled`
refuse un ID déjà actif ; `stop` couvre aussi les sessions futures.

```swift
enum BlockingPasswordResult: Equatable {
    case ok
    case wrong(remaining: Int)
    case wait(until: Date)
    case refused(reason: String)
}
```

`remaining` compte les erreurs restantes avant la première attente. La cinquième
erreur renvoie `.wait` pour 60 s ; chaque nouvelle erreur après cette attente
la double, jusqu’à 3 600 s. L’attente s’applique même au bon mot de passe.
Un succès remet le compteur à zéro. Les états sont enregistrés avant tout
arrêt/autorisation ; un échec du store ne renvoie jamais `.ok`.

`setPassword` refuse le remplacement d’un mot de passe existant. Changement et
suppression exigent l’ancien et refusent toute référence password non expirée,
y compris les sessions futures et les plages récurrentes (les retirer hors
blocage actif pour changer le mot de passe). `error` contient les refus lisibles.

`authorizeQuit` préserve tous les blocs : il accorde une seule autorisation de
fermeture, valable 30 s, liée à l’ensemble des blocs password actifs. Le hook
AppDelegate la consomme avec `consumeQuitAuthorization() -> Bool`, et révoque
une confirmation abandonnée avec `revokeQuitAuthorization()`. Un verrou
`.locked`, un programme verrouillé ou un gel simultané reste prioritaire
(`quitIsLocked: Bool`). Les fermetures système et les relances de mise à jour /
récupération de permissions gardent leur traitement préexistant.

Les pauses prévues restent disponibles sans mot de passe. `takeBreak` accepte
une pause supplémentaire de la durée déjà choisie uniquement avec le mot de
passe, et seulement sans verrou `.locked` simultané ni gel ; aucun dépassement
n’est accordé sans cette vérification. Les allowances Ralentir déjà choisies
restent inchangées.

## Modèle et stockage

- `BlockLock` : free < typing < password < locked (`strength: Int`).
- `BlockProgramRange.lock: BlockLock?`, nil = free (`effectiveLock`).
- `BlockingDocument.passwordLock: BlockPasswordLock?` ; schéma 1 conservé,
  nouveaux champs optionnels compatibles avec les anciens documents.
- `BlockPasswordLock` : `salt: Data` (16 octets aléatoires Security), `hash: Data`
  (32 octets), `iterations: Int` (200 000), `createdAt: Date`,
  `failedAttempts: Int`, `retryAfter: Date?`. PBKDF2-HMAC-SHA256 CommonCrypto ;
  comparaison du hash sur tous les octets. Jamais de mot de passe en clair dans
  le store, les diagnostics ou les erreurs.
- Un champ passwordLock manquant, mal typé ou invalide conserve le document et
  rend les verrous password effectivement locked. Aucun recours à une ancienne
  génération plus faible pour une corruption limitée au hash.
- Le fichier conserve ses permissions 0600, le dossier 0700 et les garanties
  atomiques / refus des liens existantes.

## Précisions et écarts explicites au brief

1. **Résultat enrichi** : `.refused(reason:)` ajouté aux trois cas demandés pour
   distinguer bloc introuvable, verrou définitif, credential invalide et échec
   du store d’un mot de passe incorrect.
2. Les fenêtres de programme actives sont exposées **par plage**, y compris
   quand elles se chevauchent/se touchent. La fonction historique
   `BlockingSchedule.currentWindow` garde sa fusion pour ses autres utilisateurs.
   Chaque saut n’affecte que sa plage ; le programme verrouillé impose locked.
3. Le backend ne désinscrit plus `SMAppService.mainApp` à sa fermeture : il est
   partagé avec `LaunchAtLoginManager`, dont le choix peut avoir changé depuis
   l’enregistrement. La préférence de connexion du membre reste intacte.
4. Les sessions futures survivent à une fermeture normale, même libres. Un
   verrou futur password/locked interdit aussi de désactiver le module ; ses
   listes ne deviennent plus strictes qu’au début. Supprimer une liste liée à
   une session future non libre exige d’abord d’annuler cette session, pour ne
   pas contourner sa friction via la suppression de liste.
5. Bornes de lecture : 200 000–2 000 000 tours PBKDF2 et mot de passe de
   4 096 octets UTF-8 maximum. Un credential hors bornes devient illisible,
   donc locked ; ces bornes évitent un travail arbitraire induit par un fichier
   modifié manuellement.

## Vérification

Commande requise : `swift build && swift test --filter Blocking`, avec
`HOME` et `CFFIXED_USER_HOME` pointant vers le même HOME jetable sous
`/private/tmp`. Résultat : build exit 0 ; tests exit 0, 71 tests dont 2 ignorés opt-in, zéro
échec (47 BlockingEngineTests et 8 BlockingFrictionTests). Aucune app lancée,
aucun push. Le premier build signalait un quatrième switch SwiftUI incomplet ;
sa correction minimale est incluse. Les invites natives de fermeture et
l’enregistrement effectif SMAppService n’ont pas été exercés sur l’app installée.
Logs privés :
`/private/tmp/goalong-blocking-gaps-20261007.PM3ly4/`.
