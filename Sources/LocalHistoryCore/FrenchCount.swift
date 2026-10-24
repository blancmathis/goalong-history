import Foundation

/// French count wording shared by every screen: 0 and 1 take the singular, 2 and more the plural.
/// `word` alone serves the words that agree with the count (« 3 journées Santé conservées »).
public enum FrenchCount {
    public static func word(_ n: Int, _ singular: String, _ plural: String) -> String {
        n > 1 ? plural : singular
    }

    public static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(word(n, singular, plural))"
    }
}
