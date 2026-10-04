/// Selection and transport resume are different user intents. Kept independent
/// of session accounting and audio preparation so a pending choice survives
/// a no-autoplay selection but cannot accidentally persist after playback.
public struct PlaybackSelection {
    public private(set) var restartPending = false
    public init() {}
    public mutating func select(whilePlaying: Bool) {
        if !whilePlaying { restartPending = true }
    }
    public mutating func stop() { restartPending = true }
    public mutating func consumeRestart() -> Bool {
        let result = restartPending
        restartPending = false
        return result
    }
}
