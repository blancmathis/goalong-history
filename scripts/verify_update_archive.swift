// Authenticate the feed BEFORE trusting its metadata, then verify the unopened archive.
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
final class EnclosureParser: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    var versions: [String] = []
    var current = ""
    var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        current = name; text = ""
        if name == "enclosure" { enclosures.append(attributes) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "sparkle:version" { versions.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        current = ""; text = ""
    }
}
func verifiedFeed(_ xml: Data, key: Curve25519.Signing.PublicKey) throws -> (enclosure: [String: String], version: String) {
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
    guard let url = delegate.enclosures[0]["url"],
          url.range(of: #"\Ahttps://github\.com/blancmathis/goalong-history/releases/download/(main-[0-9]+-[0-9]+|v[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.-]*)/Goalong-History-macOS-universal\.zip\z"#, options: .regularExpression) != nil,
          let lengthString = delegate.enclosures[0]["length"], let archiveLength = Int(lengthString),
          archiveLength > 0, archiveLength <= 350_000_000,
          let signatureText = delegate.enclosures[0]["sparkle:edSignature"], Data(base64Encoded: signatureText)?.count == 64 else {
        throw VerificationFailure.invalid("Invalid signed enclosure URL, size or signature")
    }
    return (delegate.enclosures[0], delegate.versions[0])
}
do {
    try require(CommandLine.arguments.count == 4, "Expected Info.plist, ZIP and feed; or --feed-only PUBLIC_KEY FEED")
    let arguments = CommandLine.arguments
    let keyString: String
    if arguments[1] == "--feed-only" { keyString = arguments[2] }
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
    if arguments[1] == "--feed-only" {
        let output: [String: String] = ["url": feed.enclosure["url"]!, "length": feed.enclosure["length"]!, "version": feed.version]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        let url = URL(fileURLWithPath: arguments[2])
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        try require(size == Int(feed.enclosure["length"]!), "Archive length differs from the authenticated feed")
        let archive = try Data(contentsOf: url, options: .mappedIfSafe)
        let signature = Data(base64Encoded: feed.enclosure["sparkle:edSignature"]!)!
        try require(key.isValidSignature(signature, for: archive), "Archive signature does not match the embedded public key")
        print("Feed and unopened archive verified against the shipped public key.")
    }
} catch {
    fputs("Update verification failed: \(error)\n", stderr)
    exit(1)
}
