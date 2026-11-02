#if os(macOS)
import CorePresentation
import Foundation
import Testing

@MainActor
private final class EffectLog {
    var calls: [String] = []
    var effects: AppSettings.Effects {
        .init(scheduledSyncChanged: { self.calls.append("schedule") },
              returnToDryRun: { self.calls.append("dry-run") },
              mcpExposureChanged: { self.calls.append("mcp:\($0)"); return .confirmed($0) })
    }
}

@MainActor
private func suite() throws -> (String, UserDefaults) {
    let name = "OpenCore.SettingsFixture.\(UUID().uuidString)"
    return (name, try #require(UserDefaults(suiteName: name)))
}

// The bug: AppSettings separately hardcoded standard defaults for reads and writes. An injected
// review suite therefore could not own either path, and edits could reach production preferences.
@Test("preference reads and writes belong to the same explicitly supplied suite")
@MainActor func preferenceSuitesStayIndependent() throws {
    let (nameA, a) = try suite(), (nameB, b) = try suite()
    defer { a.removePersistentDomain(forName: nameA); b.removePersistentDomain(forName: nameB) }
    a.set(AppSettings.AppearanceMode.light.rawValue, forKey: "ui.appearanceMode")
    a.set(0.73, forKey: "ui.glassCardOpacity")
    b.set(AppSettings.AppearanceMode.dark.rawValue, forKey: "ui.appearanceMode")
    let first = AppSettings(defaults: a, effects: .isolated)
    let second = AppSettings(defaults: b, effects: .isolated)
    #expect(first.appearanceMode == .light)
    #expect(first.glassCardOpacity == 0.73)
    #expect(second.appearanceMode == .dark)
    first.pastelAccent = .mint
    first.glassCardOpacity = 0.84
    #expect(a.string(forKey: "ui.pastelAccent") == AppSettings.PastelAccentChoice.mint.rawValue)
    #expect(a.double(forKey: "ui.glassCardOpacity") == 0.84)
    #expect(b.object(forKey: "ui.pastelAccent") == nil)
    #expect(second.pastelAccent == .sky)
    let restored = AppSettings(defaults: a, effects: .isolated)
    #expect(restored.pastelAccent == .mint)
    #expect(restored.glassCardOpacity == 0.84)
}

// Reading stored flags must not start app/controller work. Review can then construct an isolated
// model without a production shared instance or callback being invoked during initialization.
@Test("restoring preferences performs no controller callbacks")
@MainActor func restoringPreferencesHasNoEffects() throws {
    let (name, defaults) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "sync.scheduled")
    defaults.set(true, forKey: "automation.defaultDryRun")
    defaults.set(true, forKey: "mcp.exposeSensitive")
    let log = EffectLog()
    let settings = AppSettings(defaults: defaults, effects: log.effects)
    #expect(!settings.scheduledSyncEnabled)
    #expect(settings.automationDefaultDryRun)
    #expect(settings.mcpExposeSensitiveDomains)
    #expect(settings.confirmedMCPExposure == nil)
    #expect(log.calls.isEmpty)
}

@Test("preference side effects reach only the explicitly supplied callbacks")
@MainActor func preferenceCallbacksAreExplicit() throws {
    let (name, defaults) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let log = EffectLog()
    let settings = AppSettings(defaults: defaults, effects: log.effects)
    settings.scheduledSyncEnabled = false
    settings.mcpExposeSensitiveDomains = true
    settings.automationDefaultDryRun = true
    #expect(log.calls == ["schedule", "mcp:true", "dry-run"])
    #expect(defaults.bool(forKey: "mcp.exposeSensitive"))
    #expect(!defaults.bool(forKey: "sync.scheduled"))
}

// A stored false or bare assignment must never gain the confirmation that allows live control.
@Test("live automation still requires named confirmation and returning to dry run clears it")
@MainActor func automationConfirmationSurvivesExtraction() throws {
    let (name, defaults) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "automation.defaultDryRun")
    let log = EffectLog()
    let settings = AppSettings(defaults: defaults, effects: log.effects)
    #expect(!settings.automationLiveDefaultConfirmed)
    settings.confirmLiveDefault()
    #expect(settings.automationLiveDefaultConfirmed)
    #expect(!settings.automationDefaultDryRun)
    #expect(log.calls.isEmpty, "confirming a next-launch default must not start live control")
    settings.automationDefaultDryRun = true
    #expect(!settings.automationLiveDefaultConfirmed)
    #expect(log.calls == ["dry-run"])
    #expect(!defaults.bool(forKey: "automation.liveDefaultConfirmed"))
}

@Test("isolated preferences persist their state without production effect ownership")
@MainActor func isolatedPreferencesPersistLocally() throws {
    let (name, defaults) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults, effects: .isolated)
    settings.scheduledSyncEnabled = false
    settings.mcpExposeSensitiveDomains = true
    settings.automationDefaultDryRun = true
    let restored = AppSettings(defaults: defaults, effects: .isolated)
    #expect(settings.confirmedMCPExposure == nil)
    #expect(!restored.scheduledSyncEnabled)
    #expect(restored.mcpExposeSensitiveDomains)
    #expect(restored.automationDefaultDryRun)
}

@Test("chunking changes remain dirty and retrieval resets preserve their original contract")
@MainActor func preferenceDerivedValuesRemainCoherent() throws {
    let (name, defaults) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults, effects: .isolated)
    settings.chunkTargetSize += 50
    #expect(settings.chunkingDirty)
    #expect(!settings.chunkingIsDefault)
    settings.resetChunking()
    #expect(settings.chunkingIsDefault)
    #expect(settings.chunkingDirty, "resetting a preference must not claim existing objects were rebuilt")
    settings.passageLimit += 1
    #expect(!settings.retrievalIsDefault)
    settings.resetRetrieval()
    #expect(settings.retrievalIsDefault)
}
#endif
