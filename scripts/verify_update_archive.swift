// Authenticate the feed BEFORE trusting its metadata, then verify the unopened archive and deltas.
// Uses public keys only. Also used after publication, independently of the CI signing key.
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum VerificationFailure: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let text): return text } }
}
func require(_ value: Bool, _ message: String) throws {
    if !value { throw VerificationFailure.invalid(message) }
}
let archiveName = "Goalong-History-macOS-universal.zip"
let deltaPrefix = "Goalong-History-macOS-universal-from-"
final class EnclosureParser: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    var deltas: [[String: String]] = []
    var deltaLists = 0
    var inDeltas = false
    var versions: [String] = []
    var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "sparkle:deltas" { deltaLists += 1; inDeltas = true }
        if name == "enclosure" { if inDeltas { deltas.append(attributes) } else { enclosures.append(attributes) } }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "sparkle:version" { versions.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if name == "sparkle:deltas" { inDeltas = false }
        text = ""
    }
}
struct SignedFile { let url: String; let length: Int; let signature: Data }
struct Delta { let from: String; let file: SignedFile }
struct Feed { let archive: SignedFile; let version: String; let deltas: [Delta] }
func signedFile(_ attributes: [String: String]) -> SignedFile? {
    guard let url = attributes["url"], let lengthString = attributes["length"], let length = Int(lengthString),
          length > 0, length <= 350_000_000,
          let signatureText = attributes["sparkle:edSignature"], let signature = Data(base64Encoded: signatureText),
          signature.count == 64 else { return nil }
    return SignedFile(url: url, length: length, signature: signature)
}
func verifiedFeed(_ xml: Data, key: Curve25519.Signing.PublicKey) throws -> Feed {
    try require(xml.count <= 1_048_576, "Feed exceeds safety limit")
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = xml.range(of: marker, options: .backwards),
          let trailer = String(data: xml[range.lowerBound...], encoding: .utf8) else {
        throw VerificationFailure.invalid("Missing signed-feed trailer")
    }
    let expression = try NSRegularExpression(pattern: #"\A<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*\z"#)
    guard let match = expression.firstMatch(in: trailer, range: NSRange(trailer.startIndex..., in: trailer)),
          let signatureRange = Range(match.range(at: 1), in: trailer),
          let lengthRange = Range(match.range(at: 2), in: trailer),
          let signature = Data(base64Encoded: String(trailer[signatureRange])),
          let length = Int(trailer[lengthRange]), length == range.lowerBound,
          signature.count == 64 else { throw VerificationFailure.invalid("Malformed signed-feed trailer") }
    let payload = xml.prefix(length)
    try require(payload.range(of: marker) == nil, "Duplicate feed signature trailer")
    try require(key.isValidSignature(signature, for: payload), "Feed signature does not match the public trust anchor")
    // No DTD or entities are needed by a Goalong appcast; reject them outright.
    let text = String(decoding: payload, as: UTF8.self)
    try require(!text.contains("<!DOCTYPE") && !text.contains("<!ENTITY"), "Feed contains a forbidden DTD or entity")
    let delegate = EnclosureParser()
    let parser = XMLParser(data: payload)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    try require(parser.parse() && delegate.enclosures.count == 1 && delegate.versions.count == 1, "Expected one signed update enclosure and version")
    guard let archive = signedFile(delegate.enclosures[0]),
          archive.url.range(of: #"\Ahttps://github\.com/blancmathis/goalong-history/releases/download/(main-[0-9]+-[0-9]+|v[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.-]*)/Goalong-History-macOS-universal\.zip\z"#, options: .regularExpression) != nil else {
        throw VerificationFailure.invalid("Invalid signed enclosure URL, size or signature")
    }
    // A delta must live next to the archive, in the same immutable release, and name its source build.
    let release = String(archive.url.dropLast(archiveName.count))
    let version = delegate.versions[0]
    try require(delegate.deltaLists <= 1 && delegate.deltas.count <= 10, "Unexpected delta update list")
    var deltas: [Delta] = []
    for attributes in delegate.deltas {
        guard let from = attributes["sparkle:deltaFrom"],
              from.range(of: #"\A[0-9]+(\.[0-9]+){0,3}\z"#, options: .regularExpression) != nil,
              from != version, !deltas.contains(where: { $0.from == from }),
              let file = signedFile(attributes), file.url == "\(release)\(deltaPrefix)\(from).delta" else {
            throw VerificationFailure.invalid("Invalid signed delta URL, source build, size or signature")
        }
        deltas.append(Delta(from: from, file: file))
    }
    return Feed(archive: archive, version: version, deltas: deltas)
}
func verify(_ file: SignedFile, at url: URL, key: Curve25519.Signing.PublicKey, name: String) throws {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    try require(size == file.length, "\(name) length differs from the authenticated feed")
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    try require(key.isValidSignature(file.signature, for: data), "\(name) signature does not match the embedded public key")
}
do {
    let arguments = CommandLine.arguments
    let feedOnly = arguments.count > 1 && arguments[1] == "--feed-only"
    try require(arguments.count == 4 || (arguments.count == 5 && !feedOnly), "Expected Info.plist, ZIP, feed and optional delta directory; or --feed-only PUBLIC_KEY FEED")
    let keyString: String
    if feedOnly { keyString = arguments[2] }
    else {
        let infoData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let key = info["SUPublicEDKey"] as? String else { throw VerificationFailure.invalid("Missing embedded public key") }
        keyString = key
    }
    guard let keyData = Data(base64Encoded: keyString), keyData.count == 32 else { throw VerificationFailure.invalid("Invalid public key") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let xml = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
    let feed = try verifiedFeed(xml, key: key)
    if feedOnly {
        let deltas = feed.deltas.map { ["from": $0.from, "url": $0.file.url, "length": String($0.file.length)] }
        let output: [String: Any] = ["url": feed.archive.url, "length": String(feed.archive.length), "version": feed.version, "deltas": deltas]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        try verify(feed.archive, at: URL(fileURLWithPath: arguments[2]), key: key, name: "Archive")
        let directory = arguments.count == 5 ? URL(fileURLWithPath: arguments[4], isDirectory: true) : nil
        try require(feed.deltas.isEmpty || directory != nil, "The feed lists delta updates but no delta directory was given")
        if let directory {
            // Every published delta must be listed, and every listed delta must be present.
            let present = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(deltaPrefix) && $0.hasSuffix(".delta") }
            try require(Set(present) == Set(feed.deltas.map { "\(deltaPrefix)\($0.from).delta" }), "Delta files differ from the authenticated feed")
            for delta in feed.deltas {
                try verify(delta.file, at: directory.appendingPathComponent("\(deltaPrefix)\(delta.from).delta"), key: key, name: "Delta from \(delta.from)")
            }
        }
        print("Feed, unopened archive and \(feed.deltas.count) delta update(s) verified against the shipped public key.")
    }
} catch {
    fputs("Update verification failed: \(error)\n", stderr)
    exit(1)
}
