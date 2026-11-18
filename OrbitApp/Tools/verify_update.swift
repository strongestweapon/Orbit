import CryptoKit
import Foundation

// Verification only needs the app's public key, never Keychain/private-key access.
final class Enclosures: NSObject, XMLParserDelegate {
    var values: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        if elementName == "enclosure" { values.append(attributeDict) }
    }
}

func require(_ valid: Bool, _ message: String) throws {
    if !valid { throw NSError(domain: "OrbitRelease", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    let args = CommandLine.arguments
    try require(args.count == 4, "Usage: verify_update.swift feed.xml archive public-key")
    let feed = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let archiveURL = URL(fileURLWithPath: args[2])
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[3]) ?? Data())
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = feed.range(of: marker, options: .backwards) else {
        throw NSError(domain: "OrbitRelease", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing signed feed block"])
    }
    let content = feed.subdata(in: 0..<range.lowerBound)
    let block = String(decoding: feed[range.upperBound...], as: UTF8.self)
    var fields: [String: String] = [:]
    for line in block.components(separatedBy: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2 { fields[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
    }
    try require(Int(fields["length"] ?? "") == content.count, "Signed feed length mismatch")
    let feedSignature = Data(base64Encoded: fields["edSignature"] ?? "") ?? Data()
    try require(publicKey.isValidSignature(feedSignature, for: content), "Invalid feed signature")

    let enclosures = Enclosures()
    let parser = XMLParser(data: content)
    parser.delegate = enclosures
    try require(parser.parse(), "Invalid feed XML")
    let matching = enclosures.values.filter { URL(string: $0["url"] ?? "")?.lastPathComponent == archiveURL.lastPathComponent }
    try require(matching.count == 1, "Expected exactly one matching download in feed")
    let item = matching[0]
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    try require(Int(item["length"] ?? "") == archive.count, "Update archive length mismatch")
    let signature = Data(base64Encoded: item["sparkle:edSignature"] ?? "") ?? Data()
    try require(publicKey.isValidSignature(signature, for: archive), "Invalid update archive signature")
    print("Verified feed and update signatures using the public key")
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
