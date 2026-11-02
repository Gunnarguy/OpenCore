import Foundation
import Testing
@testable import CoreStore

private struct ConfigFixtureError: Error { }
private func configFixture() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-config-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("config.json"))
}

// The bug: loading with a default then re-encoding one Bool silently replaced malformed
// configuration, lost unknown fields, and hid write errors from the preference UI.
@Test("MCP configuration updates confirm readback and preserve unknown JSON fields", arguments: [false, true])
func sharedConfigPreservesUnknownFields(enabled: Bool) throws {
    let (root, path) = try configFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = Data(#"{"exposeSensitiveDomainsOverMCP":false,"future":{"values":[1,"keep",null]},"label":"retain"}"#.utf8)
    try original.write(to: path)
    #expect(SharedConfig.setMCPExposure(enabled, at: path) == .confirmed(enabled))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    let before = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
    #expect((object["future"] as? NSDictionary) == (before["future"] as? NSDictionary))
    #expect(object["label"] as? String == "retain")
    #expect(SharedConfig.load(from: path).exposeSensitiveDomainsOverMCP == enabled)
    #expect(SharedConfig.readMCPExposure(at: path) == enabled)
}

@Test("an absent MCP configuration can be initialized without inventing other fields")
func sharedConfigCreatesMissingDocument() throws {
    let (root, path) = try configFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(SharedConfig.readMCPExposure(at: path) == nil)
    #expect(SharedConfig.setMCPExposure(false, at: path) == .confirmed(false))
    #expect(SharedConfig.readMCPExposure(at: path) == false)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    #expect(Set(object.keys) == ["exposeSensitiveDomainsOverMCP"])
    #expect(SharedConfig.setMCPExposure(true, at: path) == .confirmed(true))
}

@Test("MCP update preserves a future-only object when adding the known preference")
func sharedConfigAddsKnownField() throws {
    let (root, path) = try configFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"future":"keep"}"#.utf8).write(to: path)
    #expect(SharedConfig.setMCPExposure(true, at: path) == .confirmed(true))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    #expect(object["future"] as? String == "keep")
}

@Test("malformed or incorrectly typed MCP configuration remains byte-identical", arguments: ["not-json", "[]", #"{"exposeSensitiveDomainsOverMCP":1}"#, #"{"exposeSensitiveDomainsOverMCP":null}"#, #"{"exposeSensitiveDomainsOverMCP":"true"}"#])
func sharedConfigRefusesMalformedDocument(text: String) throws {
    let (root, path) = try configFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = Data(text.utf8)
    try original.write(to: path)
    guard case .notWritten = SharedConfig.setMCPExposure(true, at: path) else { Issue.record("invalid document was not refused"); return }
    #expect(try Data(contentsOf: path) == original)
    #expect(SharedConfig.readMCPExposure(at: path) == nil)
    #expect(!SharedConfig.load(from: path).exposeSensitiveDomainsOverMCP, "legacy startup still falls back restrictively")
}

@Test("MCP configuration update refuses aliases instead of replacing a symbolic link")
func sharedConfigRefusesAlias() throws {
    let (root, path) = try configFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("linked.json")
    let original = Data(#"{"exposeSensitiveDomainsOverMCP":false}"#.utf8)
    try original.write(to: path)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
    guard case .notWritten = SharedConfig.setMCPExposure(true, at: link) else { Issue.record("alias was replaced"); return }
    #expect(try Data(contentsOf: path) == original)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == path.path)
    #expect(SharedConfig.readMCPExposure(at: link) == nil)
}

@Test("unreadable configuration cannot start an MCP preference write")
func sharedConfigReadFailureDoesNotWrite() {
    var writes = 0
    let result = SharedConfig.updateMCPExposure(true, at: URL(fileURLWithPath: "/fixture/config.json"),
        read: { _ in throw ConfigFixtureError() }, write: { _, _ in writes += 1 })
    guard case .notWritten = result else { Issue.record("preparation failure lost its phase"); return }
    #expect(writes == 0)
}

// The bug: reporting an error as unchanged would hide a partial write. A writer may change
// bytes before throwing; keep the outcome unconfirmed and never overwrite it with a rollback.
@Test("a partial MCP configuration write is unknown even when the requested value reached the file")
func sharedConfigPartialWriteRemainsUnknown() throws {
    var disk: Data? = Data(#"{"exposeSensitiveDomainsOverMCP":false,"future":"keep"}"#.utf8)
    var writes = 0
    let result = SharedConfig.updateMCPExposure(true, at: URL(fileURLWithPath: "/fixture/config.json"),
        read: { _ in disk }, write: { data, _ in writes += 1; disk = data; throw ConfigFixtureError() })
    guard case .unconfirmed = result else { Issue.record("partial write was certified or called unchanged"); return }
    #expect(writes == 1)
    let actual = try JSONDecoder().decode(SharedConfig.self, from: #require(disk))
    #expect(actual.exposeSensitiveDomainsOverMCP)
}

@Test("successful write without matching readback cannot certify MCP permissions", arguments: ["missing", "failed", "mismatched"])
func sharedConfigReadbackFailureRemainsUnknown(mode: String) {
    var reads = 0, writes = 0
    let result = SharedConfig.updateMCPExposure(true, at: URL(fileURLWithPath: "/fixture/config.json"),
        read: { _ in
            reads += 1
            if reads == 1 || mode == "missing" { return nil }
            if mode == "failed" { throw ConfigFixtureError() }
            return Data(#"{"exposeSensitiveDomainsOverMCP":false}"#.utf8)
        }, write: { _, _ in writes += 1 })
    guard case .unconfirmed = result else { Issue.record("unconfirmed readback certified startup permissions"); return }
    #expect(reads == 2)
    #expect(writes == 1)
}
