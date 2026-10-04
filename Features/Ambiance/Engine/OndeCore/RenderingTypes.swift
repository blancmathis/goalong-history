import Foundation

public enum SessionMode: String { case focus, relax, meditation }

public struct OndeError: Error, LocalizedError {
    public var code: String; public var message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}
