import CryptoKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
let key = Curve25519.Signing.PrivateKey()
let archive = Data("synthetic unopened update archive".utf8)
let zip = directory.appendingPathComponent("archive.zip")
try archive.write(to: zip)
let info = directory.appendingPathComponent("Info.plist")
try PropertyListSerialization.data(fromPropertyList: ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString()], format: .xml, options: 0).write(to: info)
let signature = try key.signature(for: archive).base64EncodedString()
let base = """
<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><sparkle:version>30000000.1.1</sparkle:version><enclosure url="https://github.com/blancmathis/goalong-history/releases/download/main-123-1/Goalong-History-macOS-universal.zip" length="\(archive.count)" sparkle:edSignature="\(signature)" /></item></channel></rss>
"""
func signed(_ value: String) throws -> Data {
    let payload = Data(value.utf8)
    let trailer = "<!-- sparkle-signatures:\nedSignature: \(try key.signature(for: payload).base64EncodedString())\nlength: \(payload.count)\n-->\n"
    return payload + Data(trailer.utf8)
}
var count = 0
func check(_ name: String, _ data: Data, pass: Bool) throws {
    let feed = directory.appendingPathComponent("feed.xml")
    try data.write(to: feed)
    let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    process.arguments = [info.path, zip.path, feed.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard (process.terminationStatus == 0) == pass else { fatalError("Unexpected verification result: \(name)") }
    count += 1; print("PASS: \(name)")
}
try check("valid signed feed and archive", signed(base), pass: true)
try check("unsigned feed", Data(base.utf8), pass: false)
let valid = try signed(base)
try check("tampered metadata", Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "main-123-1", with: "main-124-1").utf8), pass: false)
try check("appended unsigned content", valid + Data("<item>untrusted</item>".utf8), pass: false)
try check("malicious signed host", signed(base.replacingOccurrences(of: "https://github.com/", with: "https://example.com/")), pass: false)
try check("mutable download URL", signed(base.replacingOccurrences(of: "main-123-1", with: "latest-main")), pass: false)
try check("incorrect archive size", signed(base.replacingOccurrences(of: "length=\"\(archive.count)\"", with: "length=\"1\"")), pass: false)
try Data(repeating: 0, count: archive.count).write(to: zip)
try check("modified archive bytes", valid, pass: false)
try archive.write(to: zip)
let wrongKey = Curve25519.Signing.PrivateKey()
try PropertyListSerialization.data(fromPropertyList: ["SUPublicEDKey": wrongKey.publicKey.rawRepresentation.base64EncodedString()], format: .xml, options: 0).write(to: info)
try check("wrong embedded trust anchor", valid, pass: false)
print("\(count) cryptographic verification cases passed; no real signing secret used.")
