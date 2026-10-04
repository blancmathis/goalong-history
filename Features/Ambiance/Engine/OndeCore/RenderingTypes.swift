import Foundation

public enum SessionMode: String, Codable { case focus, relax, meditation }

public struct OndeError: Error, LocalizedError {
    public var code: String; public var message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}
public func jsonData(_ value: Any, pretty: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes])
}
public func jsonObject<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? NSNull() }
