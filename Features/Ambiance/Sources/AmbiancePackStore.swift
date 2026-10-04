import CryptoKit
import CoreFoundation
import Foundation

public struct AmbiancePack: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let bytes: Int64
    public let url: URL
    public let sha256: String
    public init(id: String, title: String, bytes: Int64, url: URL, sha256: String) {
        self.id = id; self.title = title; self.bytes = bytes; self.url = url; self.sha256 = sha256
    }
}

public struct AmbiancePackState: Identifiable, Equatable {
    public enum Status: Equatable { case notInstalled, downloading(Double), installed, failed(String) }
    public let id: String
    public let title: String
    public let bytes: Int64
    public var status: Status
    public init(id: String, title: String, bytes: Int64, status: Status) {
        self.id = id; self.title = title; self.bytes = bytes; self.status = status
    }
}

/// Strict, flat USTAR archives allow streaming extraction without a subprocess,
/// a remote dependency, an in-memory archive or an arbitrary filesystem path.
public struct AmbiancePackStore {
    public let root: URL
    public init(supportDirectory: URL) { root = supportDirectory.resolvingSymlinksInPath().appendingPathComponent("Ambiance", isDirectory: true) }
    private func validate(_ pack: AmbiancePack) throws {
        guard ["orchestra", "textures"].contains(pack.id), pack.bytes > 0, pack.bytes <= 256_000_000,
              pack.sha256.count == 64, pack.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw AmbianceError.invalidPack("catalogue")
        }
    }
    public func directory(_ pack: AmbiancePack) -> URL { root.appendingPathComponent(pack.id, isDirectory: true) }
    public func isInstalled(_ pack: AmbiancePack) -> Bool {
        guard (try? validate(pack)) != nil else { return false }
        let folder = directory(pack)
        guard isRegularDirectory(folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent(".installed.json")), data.count < 4096,
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["id"] as? String == pack.id, receipt["sha256"] as? String == pack.sha256,
              let number = receipt["bytes"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              receipt["bytes"] as? Int64 == pack.bytes,
              let files = receipt["files"] as? [String] else { return false }
        return files.allSatisfy { name in
            safeName(name) && isRegularFile(folder.appendingPathComponent(name))
        } && !files.isEmpty
    }
    public func install(_ pack: AmbiancePack, archive: URL, progress: (Double) -> Void = { _ in }) throws {
        try withoutActuallyEscaping(progress) { callback in
            try installVerified(pack, archive: archive, progress: callback)
        }
    }
    // Keep one extraction body instead of cloning it for each progress closure.
    // The callback is used synchronously and never retained beyond this call.
    @inline(never) private func installVerified(_ pack: AmbiancePack, archive: URL, progress: @escaping (Double) -> Void) throws {
        try checkCancellation()
        try validate(pack)
        guard isRegularFile(archive),
              (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(pack.bytes) else {
            throw AmbianceError.invalidPack("taille incorrecte")
        }
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        var hash = SHA256(), read: Int64 = 0
        while true {
            try checkCancellation()
            let count = try autoreleasepool { () throws -> Int in
                guard let block = try reader.read(upToCount: 65_536), !block.isEmpty else { return 0 }
                hash.update(data: block); return block.count
            }
            if count == 0 { break }
            read += Int64(count)
            guard read <= pack.bytes else { throw AmbianceError.invalidPack("taille incorrecte") }
            progress(Double(read) / Double(pack.bytes) * 0.45)
        }
        guard read == pack.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == pack.sha256 else {
            throw AmbianceError.invalidPack("SHA-256 incorrect")
        }
        try checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard isRegularDirectory(root), root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else {
            throw AmbianceError.invalidPack("répertoire non sûr")
        }
        let destination = directory(pack)
        guard !fm.fileExists(atPath: destination.path) else { throw AmbianceError.invalidPack("déjà installé : retirez d’abord le pack") }
        let staging = root.appendingPathComponent(".install-\(pack.id)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try reader.seek(toOffset: 0)
        var files = Set<String>(), consumed: Int64 = 0, zeroBlocks = 0
        while consumed < pack.bytes {
            try checkCancellation()
            let header = try exact(reader, 512); consumed += 512
            if header.allSatisfy({ $0 == 0 }) { zeroBlocks += 1; continue }
            guard zeroBlocks == 0, files.count < 200 else { throw AmbianceError.invalidPack("archive mal formée") }
            let name = String(decoding: header.prefix(100).prefix { $0 != 0 }, as: UTF8.self)
            guard safeName(name), files.insert(name).inserted, header[156] == 48 || header[156] == 0,
                  header[345..<500].allSatisfy({ $0 == 0 }),
                  String(decoding: header[257..<262], as: UTF8.self) == "ustar",
                  let size = octal(header[124..<136]), size <= 12_000_000 || pack.id == "textures" && size <= 20_000_000,
                  let expectedChecksum = octal(header[148..<156]) else { throw AmbianceError.invalidPack("entrée non sûre") }
            let checksum = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard checksum == expectedChecksum, Int64(size) <= pack.bytes - consumed else { throw AmbianceError.invalidPack("en-tête incorrect") }
            let target = staging.appendingPathComponent(name)
            guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AmbianceError.invalidPack("écriture impossible") }
            let writer = try FileHandle(forWritingTo: target)
            do {
                var remaining = size
                while remaining > 0 {
                    try checkCancellation()
                    let count = try autoreleasepool { () throws -> Int in
                        let block = try exact(reader, min(65_536, remaining))
                        try writer.write(contentsOf: block); return block.count
                    }
                    remaining -= count; consumed += Int64(count)
                    progress(0.45 + Double(consumed) / Double(pack.bytes) * 0.5)
                }
                try writer.close()
            } catch { try? writer.close(); throw error }
            let padding = (512 - size % 512) % 512
            if padding > 0 { _ = try exact(reader, padding); consumed += Int64(padding) }
        }
        guard zeroBlocks >= 2, consumed == pack.bytes, files.contains("LICENSE.txt"),
              pack.id != "orchestra" || files.contains("manifest.json"),
              pack.id != "textures" || Set(AmbianceSource.textures.map { $0.0 + ".wav" }).isSubset(of: files) else {
            throw AmbianceError.invalidPack("contenu incomplet")
        }
        let receipt: [String: Any] = ["id": pack.id, "sha256": pack.sha256, "bytes": pack.bytes, "files": files.sorted()]
        try JSONSerialization.data(withJSONObject: receipt).write(to: staging.appendingPathComponent(".installed.json"), options: .withoutOverwriting)
        try checkCancellation()
        // Same-volume rename publishes the complete pack, never a partially extracted folder.
        try fm.moveItem(at: staging, to: destination)
        progress(1)
    }
    public func remove(_ pack: AmbiancePack) throws {
        try validate(pack)
        let folder = directory(pack)
        guard !FileManager.default.fileExists(atPath: folder.path) || isRegularDirectory(folder),
              !FileManager.default.fileExists(atPath: root.path) || isRegularDirectory(root),
              root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else { throw AmbianceError.invalidPack("répertoire non sûr") }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    private func isRegularDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count < 100 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    private func octal(_ bytes: Data.SubSequence) -> Int? {
        Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8)
    }
    private func exact(_ reader: FileHandle, _ count: Int) throws -> Data {
        guard let data = try reader.read(upToCount: count), data.count == count else { throw AmbianceError.invalidPack("archive tronquée") }
        return data
    }
    private func checkCancellation() throws {
        if Task<Never, Never>.isCancelled { throw AmbianceError.cancelled }
    }
}
