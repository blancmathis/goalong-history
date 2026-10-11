# Panneau de la barre de menu (2026-10-11)

Maquette validée par le propriétaire : `/Users/mathisblanc/Documents/ChatGPT/be-productive/work/menubar-20261011/mockup.png` (+ `mockup.html`, notes en bas de page).

## Comportement
- Clic gauche sur l'icône : `NSPopover` (comportement `.transient`) qui contient `MenuBarPanelView` (SwiftUI, largeur 340).
- Clic droit, ⌥-clic, ou bouton « ⋯ » du panneau : l'ancien `NSMenu` actuel, inchangé.
- Le titre minuteur à côté du logo (`setFocusTitle`) reste tel quel.
- Rafraîchir le modèle à l'ouverture du panneau et chaque seconde tant qu'il est ouvert (minuteur), pas en arrière-plan.
- Le panneau ne contourne jamais une règle : liste verrouillée (Difficile, garant, séance) → `requestStopBlocking` ouvre la même friction que l'app (fenêtre de l'app, section Blocage, si pas d'API directe).
- Module désactivé (Ambiance, Concentration ou Blocage) : la section montre une ligne « Activer … » qui ouvre la page de l'app correspondante.

## Contrat vue ↔ modèle
Fichier modèle : `Sources/LocalHistoryApp/MenuBar/MenuBarPanelModel.swift` (Codex).
Fichier vue : `Sources/LocalHistoryApp/MenuBar/MenuBarPanelView.swift` (Claude, ne pas toucher).

```swift
@MainActor final class MenuBarPanelModel: ObservableObject {
    // Suivi
    enum Tracking: Equatable { case active, paused(since: Date?), attention(String) } // attention = libellé d'état (permission, disque…)
    @Published var tracking: Tracking
    @Published var trackingDetail: String          // ex. « Enregistrement local actif »
    func togglePause()                              // même effet que l'action Pause du menu actuel

    // Aujourd'hui
    struct DaySegment: Identifiable { let id: Int; let start: Double; let end: Double; let kind: Kind; enum Kind { case work, other, unclassified } } // start/end en fractions de 24 h (0…1)
    @Published var workSeconds: TimeInterval
    @Published var otherSeconds: TimeInterval
    @Published var segments: [DaySegment]
    @Published var nowFraction: Double
    func openDay()

    // Concentration
    enum FocusKind: String, CaseIterable { case pomodoro, free }
    struct FocusRun: Equatable { var phaseTitle: String; var remaining: TimeInterval?; var elapsed: TimeInterval; var progress: Double?; var cycle: Int?; var cycles: Int?; var nextBreak: Date?; var isPaused: Bool }
    @Published var focusAvailable: Bool            // module actif et suivi non en pause
    @Published var focusUnavailableReason: String? // texte court, ex. « Reprenez le suivi pour lancer une séance. »
    @Published var focusKind: FocusKind
    @Published var focusMinutes: Int               // 25 / 50 / 90 pour pomodoro
    let focusMinuteChoices: [Int]
    @Published var focusRun: FocusRun?             // nil = au repos
    func startFocus(); func pauseOrResumeFocus(); func stopFocus()

    // Ambiance
    enum AmbianceTab: String, CaseIterable { case focus, relax, texture, ownFile }
    @Published var ambianceEnabled: Bool
    @Published var ambianceSources: [AmbianceSource]        // toutes, disponibles ou non
    @Published var ambianceCurrent: AmbianceSource?         // en lecture, sinon dernière écoutée
    @Published var ambiancePlaying: Bool
    @Published var ambianceLoading: Bool
    @Published var ambianceError: String?
    @Published var ambianceVolume: Double                   // 0…1, écrit dans le contrôleur
    func togglePlay(); func playNext(); func play(_ source: AmbianceSource); func enableAmbiance()

    // Blocage
    struct BlockList: Identifiable, Equatable { let id: String; var title: String; var detail: String; var isActive: Bool; var isLocked: Bool }
    @Published var blockingEnabled: Bool
    @Published var blockLists: [BlockList]
    func setBlockList(_ id: String, active: Bool)  // seulement si !isLocked
    func requestStopBlocking(_ id: String)

    // Navigation
    func openApp(); func openSettings(); func showClassicMenu()
}
```

## Vérification
`swift build` puis la suite de tests du dépôt ; ajouter des tests unitaires du modèle (pause, séance, liste verrouillée non modifiable, `playNext` reste dans l'onglet courant).
