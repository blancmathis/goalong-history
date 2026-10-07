#if os(macOS)
import CommonCrypto
import Foundation
import Security

struct BlockPasswordLock: Codable, Equatable {
    var salt: Data
    var hash: Data
    var iterations: Int
    var createdAt: Date
    var failedAttempts = 0
    var retryAfter: Date?

    enum CodingKeys: String, CodingKey { case salt, hash, iterations, createdAt, failedAttempts, retryAfter }
    init(salt: Data, hash: Data, iterations: Int, createdAt: Date, failedAttempts: Int = 0, retryAfter: Date? = nil) {
        self.salt = salt; self.hash = hash; self.iterations = iterations; self.createdAt = createdAt
        self.failedAttempts = failedAttempts; self.retryAfter = retryAfter
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        salt = try c.decode(Data.self, forKey: .salt); hash = try c.decode(Data.self, forKey: .hash)
        iterations = try c.decode(Int.self, forKey: .iterations); createdAt = try c.decode(Date.self, forKey: .createdAt)
        failedAttempts = try c.decodeIfPresent(Int.self, forKey: .failedAttempts) ?? 0
        retryAfter = try c.decodeIfPresent(Date.self, forKey: .retryAfter)
    }

    var isValid: Bool {
        salt.count == 16 && hash.count == 32 && (200_000...2_000_000).contains(iterations)
            && createdAt.timeIntervalSince1970.isFinite && failedAttempts >= 0
            && (retryAfter?.timeIntervalSince1970.isFinite ?? true)
            && (failedAttempts < 5 || retryAfter != nil)
    }

    static func make(_ password: String, at now: Date) -> BlockPasswordLock? {
        guard !password.isEmpty, password.utf8.count <= 4_096 else { return nil }
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess,
              let hash = derive(password, salt: salt, iterations: 200_000) else { return nil }
        return BlockPasswordLock(salt: salt, hash: hash, iterations: 200_000, createdAt: now)
    }

    func matches(_ password: String) -> Bool {
        guard isValid, let candidate = Self.derive(password, salt: salt, iterations: iterations) else { return false }
        // Compare every byte, including after a mismatch.
        return zip(hash, candidate).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ password: String, salt: Data, iterations: Int) -> Data? {
        guard password.utf8.count <= 4_096 else { return nil }
        let bytes = Array(password.utf8)
        var result = Data(count: 32)
        let status = bytes.withUnsafeBytes { input in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress?.assumingMemoryBound(to: Int8.self), bytes.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        return status == kCCSuccess ? result : nil
    }
}

enum BlockingPasswordResult: Equatable {
    case ok
    case wrong(remaining: Int)
    case wait(until: Date)
    /// No password attempt occurred (missing block, hard lock, invalid credential or store failure).
    case refused(reason: String)
}
#endif
