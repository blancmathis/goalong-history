// Verify the generated archive with the public key actually embedded in the shipped app.
// This catches a stale/mismatched CI signing pair before any release becomes visible.
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

final class EnclosureParser: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "enclosure" { enclosures.append(attributes) }
    }
}

guard CommandLine.arguments.count == 4 else { fatalError("Expected app Info.plist, ZIP and appcast paths") }
let infoData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as! [String: Any]
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
let xml = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
let delegate = EnclosureParser()
let parser = XMLParser(data: xml)
parser.shouldResolveExternalEntities = false
parser.delegate = delegate
guard parser.parse(), delegate.enclosures.count == 1,
      let keyString = info["SUPublicEDKey"] as? String,
      let keyData = Data(base64Encoded: keyString),
      let signatureString = delegate.enclosures[0]["sparkle:edSignature"],
      let signature = Data(base64Encoded: signatureString),
      let length = delegate.enclosures[0]["length"], Int(length) == archive.count else {
    fatalError("Missing or invalid appcast signature metadata")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
guard key.isValidSignature(signature, for: archive) else {
    fatalError("Update signature does not match the public key in the app")
}
print("Archive signature verified against the shipped public key.")
