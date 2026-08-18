import Foundation

// MARK: - SHA-256 (dependency-free so the verification primitives also build on Linux)

public enum SHA256Digest {
    private static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))

        var h = initial
        var w = Array(repeating: UInt32(0), count: 64)

        for offset in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = offset + i * 4
                w[i] = (UInt32(message[j]) << 24)
                    | (UInt32(message[j + 1]) << 16)
                    | (UInt32(message[j + 2]) << 8)
                    | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], by: 7) ^ rotateRight(w[i - 15], by: 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], by: 17) ^ rotateRight(w[i - 2], by: 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0]
            var b = h[1]
            var c = h[2]
            var d = h[3]
            var e = h[4]
            var f = h[5]
            var g = h[6]
            var hh = h[7]

            for i in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }

        var out = Data()
        for value in h {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        return out
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func hashHex(_ data: Data) -> String {
        hex(hash(data))
    }

    public static func hashHex(_ string: String) -> String {
        hashHex(Data(string.utf8))
    }

    private static func rotateRight(_ x: UInt32, by n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

// MARK: - Canonical values

/// A deliberately small canonical representation used for commitments.
/// It avoids cross-language JSON-number edge cases by making every field a string.
public enum CanonicalFields {
    public static func encode(_ fields: [String: String]) -> Data {
        let ordered = fields.keys.sorted()
        var data = Data("LH-CANONICAL-MAP-V1\n".utf8)
        for key in ordered {
            appendLengthPrefixed(key, to: &data)
            appendLengthPrefixed(fields[key] ?? "", to: &data)
        }
        return data
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}

// MARK: - Commitments

public struct CommitmentOpening: Codable, Equatable {
    public let domain: String
    public let fields: [String: String]
    public let saltBase64: String

    public init(domain: String, fields: [String: String], saltBase64: String) {
        self.domain = domain
        self.fields = fields
        self.saltBase64 = saltBase64
    }

    public func commitmentHex() -> String? {
        guard let salt = Data(base64Encoded: saltBase64) else { return nil }
        var material = Data("LH-COMMITMENT-V1\0".utf8)
        material.append(Data(domain.utf8))
        material.append(0)
        material.append(CanonicalFields.encode(fields))
        material.append(0)
        material.append(salt)
        return SHA256Digest.hashHex(material)
    }
}

public struct LocalFieldCommitment: Codable, Equatable {
    public let name: String
    public let commitmentHex: String
    /// Stored only on the user's machine. Never sent in the minute anchor.
    public let opening: CommitmentOpening

    public init(name: String, commitmentHex: String, opening: CommitmentOpening) {
        self.name = name
        self.commitmentHex = commitmentHex
        self.opening = opening
    }
}

public enum CommitmentBuilder {
    public static func make(name: String, fields: [String: String], salt: Data) -> LocalFieldCommitment {
        let opening = CommitmentOpening(domain: "event-field:\(name)", fields: fields, saltBase64: salt.base64EncodedString())
        return LocalFieldCommitment(
            name: name,
            commitmentHex: opening.commitmentHex() ?? "",
            opening: opening
        )
    }

    public static func makeMinute(name: String, fields: [String: String], salt: Data) -> LocalFieldCommitment {
        let opening = CommitmentOpening(domain: "minute-field:\(name)", fields: fields, saltBase64: salt.base64EncodedString())
        return LocalFieldCommitment(
            name: name,
            commitmentHex: opening.commitmentHex() ?? "",
            opening: opening
        )
    }
}

// MARK: - Merkle tree

public struct MerkleStep: Codable, Equatable {
    public enum Side: String, Codable {
        case left
        case right
    }

    public let side: Side
    public let siblingHex: String

    public init(side: Side, siblingHex: String) {
        self.side = side
        self.siblingHex = siblingHex
    }
}

public enum MerkleTree {
    public static let emptyRoot = SHA256Digest.hashHex("LH-MERKLE-EMPTY-V1")

    public static func leafHash(label: String, valueHex: String) -> String {
        SHA256Digest.hashHex("LH-MERKLE-LEAF-V1\0\(label)\0\(valueHex)")
    }

    public static func nodeHash(leftHex: String, rightHex: String) -> String {
        SHA256Digest.hashHex("LH-MERKLE-NODE-V1\0\(leftHex)\0\(rightHex)")
    }

    public static func root(labeledHexValues: [(String, String)]) -> String {
        guard !labeledHexValues.isEmpty else { return emptyRoot }
        var level = labeledHexValues.map { leafHash(label: $0.0, valueHex: $0.1) }
        while level.count > 1 {
            var next: [String] = []
            var i = 0
            while i < level.count {
                let left = level[i]
                let right = i + 1 < level.count ? level[i + 1] : left
                next.append(nodeHash(leftHex: left, rightHex: right))
                i += 2
            }
            level = next
        }
        return level[0]
    }

    public static func proof(labeledHexValues: [(String, String)], index: Int) -> [MerkleStep]? {
        guard index >= 0, index < labeledHexValues.count else { return nil }
        var level = labeledHexValues.map { leafHash(label: $0.0, valueHex: $0.1) }
        var target = index
        var proof: [MerkleStep] = []

        while level.count > 1 {
            let siblingIndex = target.isMultiple(of: 2) ? target + 1 : target - 1
            let actualSibling = siblingIndex < level.count ? siblingIndex : target
            let side: MerkleStep.Side = target.isMultiple(of: 2) ? .right : .left
            proof.append(MerkleStep(side: side, siblingHex: level[actualSibling]))

            var next: [String] = []
            var i = 0
            while i < level.count {
                let left = level[i]
                let right = i + 1 < level.count ? level[i + 1] : left
                next.append(nodeHash(leftHex: left, rightHex: right))
                i += 2
            }
            target /= 2
            level = next
        }
        return proof
    }

    public static func verify(label: String, valueHex: String, proof: [MerkleStep], expectedRoot: String) -> Bool {
        var current = leafHash(label: label, valueHex: valueHex)
        for step in proof {
            switch step.side {
            case .left:
                current = nodeHash(leftHex: step.siblingHex, rightHex: current)
            case .right:
                current = nodeHash(leftHex: current, rightHex: step.siblingHex)
            }
        }
        return current == expectedRoot
    }
}

// MARK: - Shared verification helpers

public enum IntegrityDomains {
    public static let eventFieldOrder = [
        "time",
        "application",
        "context",
        "activity",
        "classification",
        "coverage",
        "trust",
        "raw_digest",
    ]

    public static let minuteFieldOrder = [
        "time",
        "events_root",
        "event_count",
        "coverage",
    ]
}

public enum ChainHash {
    public static func event(sequence: UInt64, previous: String, eventRoot: String) -> String {
        SHA256Digest.hashHex("LH-EVENT-CHAIN-V2\0\(sequence)\0\(previous)\0\(eventRoot)")
    }

    public static func anchor(sequence: UInt64, previous: String, minuteRoot: String) -> String {
        SHA256Digest.hashHex("LH-ANCHOR-CHAIN-V1\0\(sequence)\0\(previous)\0\(minuteRoot)")
    }

    public static func signingMessage(deviceID: String, sequence: UInt64, previous: String, minuteRoot: String) -> Data {
        Data("LH-ANCHOR-SIGNATURE-V1\0\(deviceID)\0\(sequence)\0\(previous)\0\(minuteRoot)".utf8)
    }
}
