import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

public enum GoalongCanonicalJSONError: Error, Equatable, LocalizedError {
    case tooLarge
    case tooDeep
    case unexpectedEnd
    case unexpectedByte(Int)
    case duplicateKey(String)
    case invalidString
    case invalidEscape
    case invalidInteger
    case trailingData
    case unsupportedValue

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "Canonical JSON exceeded its byte limit."
        case .tooDeep: return "Canonical JSON exceeded its nesting limit."
        case .unexpectedEnd: return "Canonical JSON ended unexpectedly."
        case .unexpectedByte(let byte): return "Canonical JSON contained an unexpected byte (\(byte))."
        case .duplicateKey(let key): return "Canonical JSON contained the duplicate key \(key)."
        case .invalidString: return "Canonical JSON contained an invalid UTF-8 string."
        case .invalidEscape: return "Canonical JSON contained an invalid string escape."
        case .invalidInteger: return "Canonical JSON contained a non-canonical or out-of-range integer."
        case .trailingData: return "Canonical JSON contained trailing data."
        case .unsupportedValue: return "Canonical JSON supports only null, booleans, signed integers, strings, arrays and objects."
        }
    }
}

/// The integer-only subset of RFC 8785 used by Goalong proof artifacts.
///
/// Signed schemas deliberately forbid floating-point values. Parsing is strict,
/// rejects duplicate object keys and canonicalizes object keys by UTF-16 code
/// units as required by JCS.
public indirect enum GoalongCanonicalJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([GoalongCanonicalJSONValue])
    case object([String: GoalongCanonicalJSONValue])

    public func encoded(maximumBytes: Int = 1 * 1_024 * 1_024) throws -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(512)
        try appendCanonical(to: &bytes, depth: 0, maximumBytes: maximumBytes)
        return Data(bytes)
    }

    public static func parse(
        _ data: Data,
        maximumBytes: Int = 1 * 1_024 * 1_024,
        maximumDepth: Int = 64
    ) throws -> GoalongCanonicalJSONValue {
        guard data.count <= maximumBytes else { throw GoalongCanonicalJSONError.tooLarge }
        var parser = Parser(bytes: Array(data), maximumDepth: maximumDepth)
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw GoalongCanonicalJSONError.trailingData
        }
        return value
    }

    private func appendCanonical(
        to bytes: inout [UInt8],
        depth: Int,
        maximumBytes: Int
    ) throws {
        guard depth <= 64 else { throw GoalongCanonicalJSONError.tooDeep }
        switch self {
        case .null:
            bytes.append(contentsOf: [110, 117, 108, 108])
        case .bool(true):
            bytes.append(contentsOf: [116, 114, 117, 101])
        case .bool(false):
            bytes.append(contentsOf: [102, 97, 108, 115, 101])
        case .integer(let value):
            bytes.append(contentsOf: String(value).utf8)
        case .string(let value):
            try Self.appendString(value, to: &bytes)
        case .array(let values):
            bytes.append(91)
            for (index, value) in values.enumerated() {
                if index > 0 { bytes.append(44) }
                try value.appendCanonical(
                    to: &bytes,
                    depth: depth + 1,
                    maximumBytes: maximumBytes
                )
            }
            bytes.append(93)
        case .object(let values):
            bytes.append(123)
            let ordered = values.keys.sorted(by: Self.utf16Precedes)
            for (index, key) in ordered.enumerated() {
                if index > 0 { bytes.append(44) }
                try Self.appendString(key, to: &bytes)
                bytes.append(58)
                try values[key]!.appendCanonical(
                    to: &bytes,
                    depth: depth + 1,
                    maximumBytes: maximumBytes
                )
            }
            bytes.append(125)
        }
        guard bytes.count <= maximumBytes else { throw GoalongCanonicalJSONError.tooLarge }
    }

    private static func utf16Precedes(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.utf16).lexicographicallyPrecedes(Array(rhs.utf16))
    }

    private static func appendString(_ value: String, to bytes: inout [UInt8]) throws {
        guard !value.unicodeScalars.contains(where: { (0xD800...0xDFFF).contains($0.value) }) else {
            throw GoalongCanonicalJSONError.invalidString
        }
        bytes.append(34)
        for byte in value.utf8 {
            switch byte {
            case 34: bytes.append(contentsOf: [92, 34])
            case 92: bytes.append(contentsOf: [92, 92])
            case 8: bytes.append(contentsOf: [92, 98])
            case 9: bytes.append(contentsOf: [92, 116])
            case 10: bytes.append(contentsOf: [92, 110])
            case 12: bytes.append(contentsOf: [92, 102])
            case 13: bytes.append(contentsOf: [92, 114])
            case 0...31:
                let hex = Array("0123456789abcdef".utf8)
                bytes.append(contentsOf: [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
            default:
                bytes.append(byte)
            }
        }
        bytes.append(34)
    }

    private struct Parser {
        let bytes: [UInt8]
        let maximumDepth: Int
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func parseValue(depth: Int) throws -> GoalongCanonicalJSONValue {
            guard depth <= maximumDepth else { throw GoalongCanonicalJSONError.tooDeep }
            skipWhitespace()
            guard index < bytes.count else { throw GoalongCanonicalJSONError.unexpectedEnd }
            switch bytes[index] {
            case 110:
                try consume("null")
                return .null
            case 116:
                try consume("true")
                return .bool(true)
            case 102:
                try consume("false")
                return .bool(false)
            case 34:
                return .string(try parseString())
            case 91:
                return try parseArray(depth: depth + 1)
            case 123:
                return try parseObject(depth: depth + 1)
            case 45, 48...57:
                return .integer(try parseInteger())
            default:
                throw GoalongCanonicalJSONError.unexpectedByte(Int(bytes[index]))
            }
        }

        mutating func consume(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                Array(bytes[index..<(index + expected.count)]) == expected
            else { throw GoalongCanonicalJSONError.unexpectedEnd }
            index += expected.count
        }

        mutating func parseArray(depth: Int) throws -> GoalongCanonicalJSONValue {
            index += 1
            skipWhitespace()
            var values: [GoalongCanonicalJSONValue] = []
            if index < bytes.count, bytes[index] == 93 {
                index += 1
                return .array(values)
            }
            while true {
                values.append(try parseValue(depth: depth))
                skipWhitespace()
                guard index < bytes.count else { throw GoalongCanonicalJSONError.unexpectedEnd }
                if bytes[index] == 93 {
                    index += 1
                    return .array(values)
                }
                guard bytes[index] == 44 else {
                    throw GoalongCanonicalJSONError.unexpectedByte(Int(bytes[index]))
                }
                index += 1
            }
        }

        mutating func parseObject(depth: Int) throws -> GoalongCanonicalJSONValue {
            index += 1
            skipWhitespace()
            var values: [String: GoalongCanonicalJSONValue] = [:]
            if index < bytes.count, bytes[index] == 125 {
                index += 1
                return .object(values)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 34 else {
                    throw index < bytes.count
                        ? GoalongCanonicalJSONError.unexpectedByte(Int(bytes[index]))
                        : GoalongCanonicalJSONError.unexpectedEnd
                }
                let key = try parseString()
                guard values[key] == nil else { throw GoalongCanonicalJSONError.duplicateKey(key) }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 58 else {
                    throw index < bytes.count
                        ? GoalongCanonicalJSONError.unexpectedByte(Int(bytes[index]))
                        : GoalongCanonicalJSONError.unexpectedEnd
                }
                index += 1
                values[key] = try parseValue(depth: depth)
                skipWhitespace()
                guard index < bytes.count else { throw GoalongCanonicalJSONError.unexpectedEnd }
                if bytes[index] == 125 {
                    index += 1
                    return .object(values)
                }
                guard bytes[index] == 44 else {
                    throw GoalongCanonicalJSONError.unexpectedByte(Int(bytes[index]))
                }
                index += 1
            }
        }

        mutating func parseString() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else {
                throw GoalongCanonicalJSONError.invalidString
            }
            index += 1
            var output: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 {
                    guard let value = String(bytes: output, encoding: .utf8) else {
                        throw GoalongCanonicalJSONError.invalidString
                    }
                    return value
                }
                if byte == 92 {
                    guard index < bytes.count else { throw GoalongCanonicalJSONError.unexpectedEnd }
                    let escaped = bytes[index]
                    index += 1
                    switch escaped {
                    case 34, 47, 92: output.append(escaped)
                    case 98: output.append(8)
                    case 102: output.append(12)
                    case 110: output.append(10)
                    case 114: output.append(13)
                    case 116: output.append(9)
                    case 117:
                        let first = try parseHexCodeUnit()
                        let scalar: UInt32
                        if (0xD800...0xDBFF).contains(first) {
                            guard index + 2 <= bytes.count, bytes[index] == 92, bytes[index + 1] == 117 else {
                                throw GoalongCanonicalJSONError.invalidEscape
                            }
                            index += 2
                            let second = try parseHexCodeUnit()
                            guard (0xDC00...0xDFFF).contains(second) else {
                                throw GoalongCanonicalJSONError.invalidEscape
                            }
                            scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                        } else {
                            guard !(0xDC00...0xDFFF).contains(first) else {
                                throw GoalongCanonicalJSONError.invalidEscape
                            }
                            scalar = first
                        }
                        guard let unicode = UnicodeScalar(scalar) else {
                            throw GoalongCanonicalJSONError.invalidEscape
                        }
                        output.append(contentsOf: String(unicode).utf8)
                    default:
                        throw GoalongCanonicalJSONError.invalidEscape
                    }
                } else {
                    guard byte >= 0x20 else { throw GoalongCanonicalJSONError.invalidString }
                    output.append(byte)
                }
            }
            throw GoalongCanonicalJSONError.unexpectedEnd
        }

        mutating func parseHexCodeUnit() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw GoalongCanonicalJSONError.unexpectedEnd }
            var value: UInt32 = 0
            for byte in bytes[index..<(index + 4)] {
                let nibble: UInt32
                switch byte {
                case 48...57: nibble = UInt32(byte - 48)
                case 65...70: nibble = UInt32(byte - 55)
                case 97...102: nibble = UInt32(byte - 87)
                default: throw GoalongCanonicalJSONError.invalidEscape
                }
                value = value * 16 + nibble
            }
            index += 4
            return value
        }

        mutating func parseInteger() throws -> Int64 {
            let start = index
            if bytes[index] == 45 { index += 1 }
            guard index < bytes.count else { throw GoalongCanonicalJSONError.invalidInteger }
            if bytes[index] == 48 {
                index += 1
                if index < bytes.count, (48...57).contains(bytes[index]) {
                    throw GoalongCanonicalJSONError.invalidInteger
                }
            } else {
                guard (49...57).contains(bytes[index]) else {
                    throw GoalongCanonicalJSONError.invalidInteger
                }
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            }
            if index < bytes.count, [46, 69, 101].contains(bytes[index]) {
                throw GoalongCanonicalJSONError.unsupportedValue
            }
            guard let string = String(bytes: bytes[start..<index], encoding: .utf8),
                let value = Int64(string),
                string != "-0"
            else { throw GoalongCanonicalJSONError.invalidInteger }
            return value
        }
    }
}

public enum GoalongBase64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) -> Data? {
        guard !value.contains("="), value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        return Data(base64Encoded: base64)
    }
}

public enum GoalongProofDigest {
    public static func sha256(_ data: Data) -> String {
        "sha256:\(GoalongBase64URL.encode(SHA256Digest.hash(data)))"
    }

    public static func isValid(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"),
            let data = GoalongBase64URL.decode(String(value.dropFirst(7)))
        else { return false }
        return data.count == 32
    }
}

public struct GoalongJWSVerification: Equatable, Sendable {
    public let valid: Bool
    public let payload: Data?
    public let keyID: String?
    public let issue: String?

    public init(valid: Bool, payload: Data?, keyID: String?, issue: String?) {
        self.valid = valid
        self.payload = payload
        self.keyID = keyID
        self.issue = issue
    }
}

public enum GoalongES256JWS {
    public static let algorithm = "ES256"

    public static func keyID(publicKeyX963: Data) -> String? {
        guard let spki = subjectPublicKeyInfo(publicKeyX963: publicKeyX963) else { return nil }
        return GoalongProofDigest.sha256(spki)
    }

    public static func compact(
        canonicalPayload: Data,
        type: String,
        publicKeyX963: Data,
        signDER: (Data) throws -> Data
    ) throws -> String {
        let parsed = try GoalongCanonicalJSONValue.parse(canonicalPayload)
        guard try parsed.encoded() == canonicalPayload else {
            throw GoalongCanonicalJSONError.unsupportedValue
        }
        guard let kid = keyID(publicKeyX963: publicKeyX963) else {
            throw GoalongCanonicalJSONError.unsupportedValue
        }
        let header = GoalongCanonicalJSONValue.object([
            "alg": .string(algorithm),
            "kid": .string(kid),
            "typ": .string(type),
        ])
        let headerData = try header.encoded(maximumBytes: 4 * 1_024)
        let encodedHeader = GoalongBase64URL.encode(headerData)
        let encodedPayload = GoalongBase64URL.encode(canonicalPayload)
        let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let derSignature = try signDER(signingInput)
        guard let signature = normalizedRawSignature(fromDER: derSignature) else {
            throw GoalongCanonicalJSONError.unsupportedValue
        }
        return "\(encodedHeader).\(encodedPayload).\(GoalongBase64URL.encode(signature))"
    }

    public static func verify(
        _ compact: String,
        expectedType: String,
        publicKeyX963: Data,
        maximumPayloadBytes: Int = 64 * 1_024
    ) -> GoalongJWSVerification {
        #if canImport(CryptoKit)
            let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3,
                let headerData = GoalongBase64URL.decode(String(parts[0])),
                let payload = GoalongBase64URL.decode(String(parts[1])),
                let rawSignature = GoalongBase64URL.decode(String(parts[2])),
                payload.count <= maximumPayloadBytes,
                rawSignature.count == 64
            else {
                return GoalongJWSVerification(valid: false, payload: nil, keyID: nil, issue: "invalid_compact_jws")
            }
            guard isLowS(rawSignature) else {
                return GoalongJWSVerification(valid: false, payload: payload, keyID: nil, issue: "non_canonical_signature")
            }
            do {
                let headerValue = try GoalongCanonicalJSONValue.parse(headerData, maximumBytes: 4 * 1_024)
                guard try headerValue.encoded(maximumBytes: 4 * 1_024) == headerData,
                    case .object(let header) = headerValue,
                    header.count == 3,
                    header["alg"] == .string(algorithm),
                    header["typ"] == .string(expectedType),
                    case .string(let kid)? = header["kid"],
                    kid == keyID(publicKeyX963: publicKeyX963)
                else {
                    return GoalongJWSVerification(valid: false, payload: payload, keyID: nil, issue: "invalid_protected_header")
                }
                let payloadValue = try GoalongCanonicalJSONValue.parse(payload, maximumBytes: maximumPayloadBytes)
                guard try payloadValue.encoded(maximumBytes: maximumPayloadBytes) == payload else {
                    return GoalongJWSVerification(valid: false, payload: payload, keyID: kid, issue: "non_canonical_payload")
                }
                let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyX963)
                let signature = try P256.Signing.ECDSASignature(rawRepresentation: rawSignature)
                let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
                guard publicKey.isValidSignature(signature, for: signingInput) else {
                    return GoalongJWSVerification(valid: false, payload: payload, keyID: kid, issue: "invalid_signature")
                }
                return GoalongJWSVerification(valid: true, payload: payload, keyID: kid, issue: nil)
            } catch {
                return GoalongJWSVerification(valid: false, payload: payload, keyID: nil, issue: "malformed_jws")
            }
        #else
            return GoalongJWSVerification(valid: false, payload: nil, keyID: nil, issue: "cryptokit_unavailable")
        #endif
    }

    public static func subjectPublicKeyInfo(publicKeyX963: Data) -> Data? {
        guard publicKeyX963.count == 65, publicKeyX963.first == 0x04 else { return nil }
        var output = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE,
            0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
            0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ])
        output.append(publicKeyX963)
        return output
    }

    private static func normalizedRawSignature(fromDER der: Data) -> Data? {
        #if canImport(CryptoKit)
            guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else {
                return nil
            }
            var raw = Data(signature.rawRepresentation)
            guard raw.count == 64 else { return nil }
            if !isLowS(raw) {
                let order: [UInt8] = [
                    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
                    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                    0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
                    0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
                ]
                let s = Array(raw.suffix(32))
                guard let normalized = subtract(order, s) else { return nil }
                raw.replaceSubrange(32..<64, with: normalized)
            }
            return raw
        #else
            return nil
        #endif
    }

    private static func isLowS(_ raw: Data) -> Bool {
        guard raw.count == 64 else { return false }
        let halfOrder: [UInt8] = [
            0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
            0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42,
            0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
        ]
        return !halfOrder.lexicographicallyPrecedes(Array(raw.suffix(32)))
    }

    private static func subtract(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8]? {
        guard lhs.count == rhs.count, !lhs.lexicographicallyPrecedes(rhs) else { return nil }
        var output = Array(repeating: UInt8(0), count: lhs.count)
        var borrow = 0
        for index in stride(from: lhs.count - 1, through: 0, by: -1) {
            var value = Int(lhs[index]) - Int(rhs[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            output[index] = UInt8(value)
        }
        return borrow == 0 ? output : nil
    }
}
