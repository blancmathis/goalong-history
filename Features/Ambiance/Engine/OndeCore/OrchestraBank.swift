import Foundation
import Darwin
import CryptoKit
import OndeDSP

/// Goalong adaptation: no process-wide cache, no bundle lookup. Each DSP owns
/// only the immutable sample copies its score can actually schedule.
public enum OrchestraBank {
    public struct Loaded {
        public let samples: Int
        public let mappings: [MappedNote]
        public var mappedBytes: Int { mappings.reduce(0) { $0 + $1.byteCount } }
        public var copiedBytes: Int { 0 }
    }
    /// POSIX mappings guarantee a stable pointer through C rendering. Unlike a
    /// pointer borrowed from Data.withUnsafeBytes, its lifetime is explicit.
    public final class MappedNote {
        public let byteCount: Int
        private let address: UnsafeMutableRawPointer
        public let frames: UInt32
        public let rate: Double
        public let pcm: UnsafePointer<Int16>
        init(url: URL, expectedFrames: Int, expectedRate: Double, digest: String) throws {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw OndeError("orchestra_invalid", "Instrument inaccessible.") }
            defer { close(fd) }
            var attributes = stat()
            guard fstat(fd, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG,
                  attributes.st_size >= 44, attributes.st_size <= 12_000_000 else { throw OndeError("orchestra_invalid", "Instrument invalide.") }
            byteCount = Int(attributes.st_size)
            // Verify through bounded reads, before mapping. Hashing a mapped file
            // would fault the entire bank into process RSS before the first note.
            let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var hash = SHA256(), read = 0
            while let block = try reader.read(upToCount: 65_536), !block.isEmpty {
                if Task<Never, Never>.isCancelled { throw CancellationError() }
                hash.update(data: block); read += block.count
            }
            guard read == byteCount, hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
                throw OndeError("orchestra_checksum", "Intégrité de l’instrument invalide.")
            }
            guard let mapped = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, fd, 0), mapped != MAP_FAILED else {
                throw OndeError("orchestra_invalid", "Mappage impossible.")
            }
            do {
                let bytes = UnsafeRawBufferPointer(start: mapped, count: byteCount)
                func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
                func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
                func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
                guard tag(0) == "RIFF", tag(8) == "WAVE", u32(4) + 8 == byteCount else { throw OndeError("orchestra_invalid", "WAV invalide.") }
                var cursor = 12, formatValid = false, audioOffset: Int?, audioBytes = 0
                while cursor + 8 <= byteCount {
                    let size = u32(cursor + 4), start = cursor + 8
                    guard size <= byteCount - start else { throw OndeError("orchestra_invalid", "WAV tronqué.") }
                    if tag(cursor) == "fmt " {
                        guard size >= 16, u16(start) == 1, u16(start + 2) == 2,
                              u16(start + 12) == 4, u16(start + 14) == 16,
                              Double(u32(start + 4)) == expectedRate, u32(start + 8) == Int(expectedRate) * 4 else {
                            throw OndeError("orchestra_invalid", "Format PCM16 stéréo requis.")
                        }
                        formatValid = true
                    } else if tag(cursor) == "data" {
                        guard audioOffset == nil else { throw OndeError("orchestra_invalid", "WAV ambigu.") }
                        audioOffset = start; audioBytes = size
                    }
                    cursor = start + size + size % 2
                }
                guard formatValid, let offset = audioOffset, offset % 2 == 0, (64...1_500_000).contains(expectedFrames),
                      audioBytes == expectedFrames * 4, expectedRate.isFinite, (8000...96000).contains(expectedRate) else {
                    throw OndeError("orchestra_invalid", "Données PCM invalides.")
                }
                address = mapped; frames = UInt32(expectedFrames); rate = expectedRate
                pcm = UnsafePointer(mapped.advanced(by: offset).assumingMemoryBound(to: Int16.self))
            } catch { munmap(mapped, byteCount); throw error }
        }
        deinit { munmap(address, byteCount) }
    }
    public static func instruments(for configuration: GenerativeSettings) -> Set<Int> {
        switch Int(configuration.composition) {
        case 1, 7, 8, 13: return []
        case 2: return [1, 2, 11]
        case 3: return [0, 1, 2, 3, 4, 5, 6, 8, 9]
        case 4: return [1, 2, 8, 10]
        case 5: return [11]
        case 6: return [2, 8, 10]
        case 9: return [2, 11]
        case 10: return [0, 1, 2, 5, 6, 7]
        case 11, 12: return [2, 8]
        default: return configuration.orchestra > 0 || configuration.piano > 0 ? Set(0...11) : []
        }
    }
    @discardableResult public static func load(into core: OpaquePointer, required: Bool,
                                               directory: URL?, configuration: GenerativeSettings) throws -> Loaded {
        let instruments = instruments(for: configuration)
        guard let directory else {
            if required { throw OndeError("orchestra_missing", "Le pack Orchestre est manquant.") }
            return Loaded(samples: 0, mappings: [])
        }
        let manifest = directory.appendingPathComponent("manifest.json")
        let manifestSize = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard manifestSize < 2_000_000 else { throw OndeError("orchestra_invalid", "Manifeste trop volumineux.") }
        let data = try Data(contentsOf: manifest, options: .alwaysMapped)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["license"] as? String == "CC0-1.0", let samples = object["samples"] as? [[String: Any]],
              (11...112).contains(samples.count) else { throw OndeError("orchestra_invalid", "Manifeste Orchestre invalide.") }
        var total = 0, count = 0, mappings: [MappedNote] = []
        for item in samples {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            guard let instrument = item["instrument"] as? Int, (0...11).contains(instrument) else {
                throw OndeError("orchestra_invalid", "Instrument invalide.")
            }
            guard instruments.contains(instrument) else { continue }
            try autoreleasepool {
                guard let name = item["filename"] as? String, !name.isEmpty, !name.hasPrefix("."),
                      name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("\\"),
                      let root = item["root_midi"] as? Int, (0...127).contains(root),
                      let rr = item["round_robin"] as? Int, (0...7).contains(rr),
                      let digest = item["processed_sha256"] as? String else { throw OndeError("orchestra_invalid", "Métadonnées invalides.") }
                let url = directory.appendingPathComponent(name)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= 12_000_000 else { throw OndeError("orchestra_invalid", "Fichier instrument invalide.") }
                guard let frames = item["frames"] as? Int, let rate = item["sample_rate"] as? Double else {
                    throw OndeError("orchestra_invalid", "Métadonnées PCM invalides.")
                }
                let note = try MappedNote(url: url, expectedFrames: frames, expectedRate: rate, digest: digest)
                total += frames
                guard total <= 24_000_000,
                      onde_dsp_add_pcm16_sample(core, Int32(instrument), Int32(root), Int32(rr), note.pcm, note.frames, note.rate) == 1 else {
                    throw OndeError("orchestra_invalid", "Chargement instrument impossible.")
                }
                mappings.append(note)
                count += 1
            }
        }
        let requiredMask = instruments.reduce(0) { $0 | (1 << $1) }
        guard Int(onde_dsp_orchestra_families(core)) & requiredMask == requiredMask else {
            throw OndeError("orchestra_incomplete", "Le pack ne contient pas les instruments de cette composition.")
        }
        return Loaded(samples: count, mappings: mappings)
    }
}
