import Foundation

/// One short English sentence for an error that people or ChatGPT read.
/// It never returns a Swift dump such as `keyNotFound(CodingKeys(…), Context(…))`.
public enum GoalongReadableError {
    public static func message(_ error: Error) -> String {
        if let decoding = error as? DecodingError { return describe(decoding) }
        if let text = (error as? LocalizedError)?.errorDescription, !text.isEmpty { return text }
        let ns = error as NSError
        if let text = ns.userInfo[NSLocalizedDescriptionKey] as? String, !text.isEmpty { return text }
        // A real NSError has a system sentence; its `description` is the `Error Domain=…` dump.
        if type(of: error) is NSError.Type || [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain].contains(ns.domain) {
            return error.localizedDescription
        }
        if let text = (error as? CustomStringConvertible)?.description, !text.isEmpty, !text.hasPrefix("Error Domain=") {
            return text
        }
        let name = String(describing: error).prefix { $0 != "(" }
        return "The operation failed (\(String(describing: type(of: error))): \(name))."
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "The data is missing the field \"\(key.stringValue)\"\(location(context))."
        case .valueNotFound(_, let context):
            return "The data has an empty value\(location(context))."
        case .typeMismatch(_, let context):
            return "The data has a value of the wrong type\(location(context))."
        case .dataCorrupted(let context):
            let reason = context.debugDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return "The data is not readable: \(reason.isEmpty ? "it is corrupted" : reason)\(location(context))."
        @unknown default:
            return "The data could not be decoded."
        }
    }

    private static func location(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? "" : " at \(path)"
    }
}
