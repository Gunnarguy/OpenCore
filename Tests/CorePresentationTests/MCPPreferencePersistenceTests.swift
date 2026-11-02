#if os(macOS)
import CorePresentation
import CoreStore
import Foundation
import Testing

@MainActor private func preferenceFixture(_ result: SharedConfig.MCPExposureWriteResult?) throws -> (AppSettings, UserDefaults, String) {
    let name = "OpenCore.MCPPreferenceFixture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    let settings = AppSettings(defaults: defaults, effects: .init(
        scheduledSyncChanged: {}, returnToDryRun: {}, mcpExposureChanged: { _ in result }))
    return (settings, defaults, name)
}

// The bug: the requested defaults Bool was presented as successfully saved shared state and
// unlocked the playground even when SharedConfig.save failed or had never been attempted.
@Test("MCP requested preferences are unverified until a matching write result arrives")
@MainActor func mcpRequestedPreferenceIsNotConfirmed() throws {
    let (settings, defaults, name) = try preferenceFixture(nil)
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(settings.confirmedMCPExposure == nil)
    settings.mcpExposeSensitiveDomains = true
    #expect(defaults.bool(forKey: "mcp.exposeSensitive"))
    #expect(settings.confirmedMCPExposure == nil)
    #expect(settings.mcpExposureWriteResult == nil)
    settings.observeInitialMCPStartupConfiguration(true)
    #expect(settings.confirmedMCPExposure == nil, "an attempted unconfirmed change cannot regain authority from observation")
}

@Test("failed MCP saves keep requested and actual permissions separate", arguments: [false, true])
@MainActor func mcpSaveFailureIsNotConfirmed(partial: Bool) throws {
    let result: SharedConfig.MCPExposureWriteResult = partial ? .unconfirmed("partial fixture") : .notWritten("preparation fixture")
    let (settings, defaults, name) = try preferenceFixture(result)
    defer { defaults.removePersistentDomain(forName: name) }
    settings.mcpExposeSensitiveDomains = true
    #expect(settings.mcpExposeSensitiveDomains)
    #expect(settings.mcpExposureWriteResult == result)
    #expect(settings.confirmedMCPExposure == nil)
    #expect(settings.mcpExposureWriteResult?.failureDescription != nil)
    settings.observeInitialMCPStartupConfiguration(true)
    #expect(settings.confirmedMCPExposure == nil)
}

@Test("strict initial shared observation restores saved authorization without repeating a write", arguments: [false, true])
@MainActor func mcpInitialObservationRestoresSavedSetting(enabled: Bool) throws {
    let (settings, defaults, name) = try preferenceFixture(nil)
    defer { defaults.removePersistentDomain(forName: name) }
    settings.observeInitialMCPStartupConfiguration(enabled)
    #expect(settings.confirmedMCPExposure == enabled)
    #expect(settings.mcpExposureWriteResult == nil, "an observed file is not a write result")
    #expect(defaults.object(forKey: "mcp.exposeSensitive") == nil)
    #expect(settings.revalidateMCPStartupConfirmation(currentSharedSetting: enabled))
    #expect(!settings.revalidateMCPStartupConfirmation(currentSharedSetting: !enabled))
    settings.observeInitialMCPStartupConfiguration(enabled)
    #expect(settings.confirmedMCPExposure == nil, "an invalidated observation cannot resurrect itself")
}

// The bug: optional nil was also used as the not-yet-observed sentinel, so a failed initial
// read could later silently authorize true through the initialization path.
@Test("an unknown initial MCP observation consumes initialization without authorizing a later read")
@MainActor func mcpUnknownInitialObservationIsConsumed() throws {
    let (settings, defaults, name) = try preferenceFixture(nil)
    defer { defaults.removePersistentDomain(forName: name) }
    settings.observeInitialMCPStartupConfiguration(nil)
    settings.observeInitialMCPStartupConfiguration(true)
    #expect(settings.confirmedMCPExposure == nil)
    #expect(!settings.revalidateMCPStartupConfirmation(currentSharedSetting: true))
    #expect(defaults.object(forKey: "mcp.exposeSensitive") == nil)
}

@Test("only matching observed MCP startup values are confirmed", arguments: [false, true])
@MainActor func mcpMatchingWriteIsConfirmed(enabled: Bool) throws {
    let (settings, defaults, name) = try preferenceFixture(.confirmed(enabled))
    defer { defaults.removePersistentDomain(forName: name) }
    settings.mcpExposeSensitiveDomains = enabled
    #expect(settings.confirmedMCPExposure == enabled)
    #expect(settings.mcpExposureWriteResult == .confirmed(enabled))
    #expect(settings.revalidateMCPStartupConfirmation(currentSharedSetting: enabled))
}

@Test("external MCP configuration changes invalidate cached confirmation before copying or a new server", arguments: [false, true])
@MainActor func mcpExternalChangeInvalidatesConfirmation(enabled: Bool) throws {
    let (settings, defaults, name) = try preferenceFixture(.confirmed(enabled))
    defer { defaults.removePersistentDomain(forName: name) }
    settings.mcpExposeSensitiveDomains = enabled
    #expect(!settings.revalidateMCPStartupConfirmation(currentSharedSetting: !enabled))
    #expect(settings.confirmedMCPExposure == nil)
    #expect(!settings.revalidateMCPStartupConfirmation(currentSharedSetting: enabled), "a later read cannot resurrect confirmation")
}

@Test("unknown shared MCP configuration cannot validate a prior save or an unconfirmed request")
@MainActor func mcpUnknownReadInvalidatesConfirmation() throws {
    let (settings, defaults, name) = try preferenceFixture(.confirmed(true))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(!settings.revalidateMCPStartupConfirmation(currentSharedSetting: true))
    settings.mcpExposeSensitiveDomains = true
    #expect(!settings.revalidateMCPStartupConfirmation(currentSharedSetting: nil))
    #expect(settings.confirmedMCPExposure == nil)
}

@Test("a mismatched MCP write result cannot unlock the playground or certify a restrictive save")
@MainActor func mcpMismatchedWriteIsUnknown() throws {
    let (settings, defaults, name) = try preferenceFixture(.confirmed(false))
    defer { defaults.removePersistentDomain(forName: name) }
    settings.mcpExposeSensitiveDomains = true
    #expect(settings.confirmedMCPExposure == nil)
    guard case .unconfirmed = settings.mcpExposureWriteResult else { Issue.record("mismatched readback was trusted"); return }
}

@Test("blocking MCP access can retry the same requested value and clears stale confirmation")
@MainActor func mcpRestrictiveSaveCanRetry() throws {
    let name = "OpenCore.MCPPreferenceFixture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var calls = 0
    let settings = AppSettings(defaults: defaults, effects: .init(scheduledSyncChanged: {}, returnToDryRun: {},
        mcpExposureChanged: { enabled in calls += 1; return calls == 1 ? .confirmed(enabled) : .unconfirmed("retry fixture") }))
    settings.mcpExposeSensitiveDomains = false
    #expect(settings.confirmedMCPExposure == false)
    settings.mcpExposeSensitiveDomains = false
    #expect(calls == 2)
    #expect(settings.confirmedMCPExposure == nil)
}

// The bug: generated --unsafe-expose-sensitive overrides survive later shared-config blocks.
@Test("generated MCP clients contain no unsafe override and preserve command strings")
@MainActor func mcpClientExampleHasNoUnsafeOverride() throws {
    let command = "/fixture/a \"quoted\" directory/line\n\\opencore"
    let text = try #require(AppSettings.mcpClientConfiguration(command: command))
    let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let servers = try #require(root["mcpServers"] as? [String: Any])
    let server = try #require(servers["opencore"] as? [String: Any])
    #expect(server["command"] as? String == command)
    #expect(server["args"] as? [String] == ["mcp"])
}
#endif
