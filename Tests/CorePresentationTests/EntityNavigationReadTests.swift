#if os(macOS)
import CoreModel
import CorePresentation
import Foundation
import Testing
@testable import CoreStore

private let atlas = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project)
private let birch = CoreEntity(kind: .project, canonicalName: "Birch", domain: .project)
private func fixtureDossier(_ entity: CoreEntity) -> EntityDossier {
    EntityDossier(entity: entity, claims: [], contradictions: [], events: [], aliases: [])
}
private struct NavigationFixtureError: LocalizedError {
    var errorDescription: String? { "fixture lookup failed" }
}

@MainActor private final class NavigationReadGate {
    private var continuation: CheckedContinuation<EntityDossier?, Never>?
    private var released = false
    private var value: EntityDossier?
    private(set) var started = false
    func read() async -> EntityDossier? {
        started = true
        if released { return value }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: EntityDossier?) {
        released = true
        self.value = value
        continuation?.resume(returning: value)
        continuation = nil
    }
    func waitForRead() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !started, ContinuousClock.now < deadline { await Task.yield() }
        #expect(started, "the controlled read did not start")
    }
}

// The bug: an explicit name jump first selected the list's first entity, then silently kept it
// when resolution failed. Only the requested target may produce a completed dossier outcome.
@Test("entity navigation resolves the exact requested name instead of a default row")
@MainActor func entityNavigationExactTarget() async {
    var readIDs: [EntityID] = []
    let outcome = await EntityNavigationRead.run(target: .name("bIrCh"), knownEntities: [atlas, birch],
        resolve: { _ in Issue.record("an exact canonical name should not require alias lookup"); return [] },
        read: { id in readIDs.append(id); return fixtureDossier(birch) }, isCurrent: { true })
    guard case .loaded(let dossier) = outcome else { Issue.record("requested dossier was not loaded"); return }
    #expect(dossier.entity.id == birch.id)
    #expect(readIDs == [birch.id])
}

@Test("entity navigation alias resolution reads the returned target")
@MainActor func entityNavigationAliasTarget() async {
    var names: [String] = [], readIDs: [EntityID] = []
    let outcome = await EntityNavigationRead.run(target: .name("Birch alias"), knownEntities: [atlas],
        resolve: { names.append($0); return [birch, atlas] },
        read: { readIDs.append($0); return fixtureDossier(birch) }, isCurrent: { true })
    guard case .loaded(let dossier) = outcome else { Issue.record("alias dossier was not loaded"); return }
    #expect(dossier.entity.id == birch.id)
    #expect(names == ["Birch alias"])
    #expect(readIDs == [birch.id])
}

@Test("missing entity navigation never reads or completes an unrelated default dossier")
@MainActor func entityNavigationMissingName() async {
    var reads = 0
    let outcome = await EntityNavigationRead.run(target: .name("Missing"), knownEntities: [atlas],
        resolve: { _ in [] }, read: { _ in reads += 1; return fixtureDossier(atlas) }, isCurrent: { true })
    guard case .notFound = outcome else { Issue.record("missing target did not remain missing"); return }
    #expect(reads == 0)
}

@Test("entity navigation preserves lookup and dossier failures instead of reporting completion", arguments: [false, true])
@MainActor func entityNavigationReadFailure(duringRead: Bool) async {
    let outcome = await EntityNavigationRead.run(target: .name("Birch alias"), knownEntities: [atlas],
        resolve: { _ in if !duringRead { throw NavigationFixtureError() }; return [birch] },
        read: { _ in throw NavigationFixtureError() }, isCurrent: { true })
    guard case .failed(let message) = outcome else { Issue.record("failed operation reported another outcome"); return }
    #expect(message == "fixture lookup failed")
}

@Test("a missing or mismatched dossier cannot complete the requested entity", arguments: [false, true])
@MainActor func entityNavigationInvalidDossier(mismatched: Bool) async {
    let outcome = await EntityNavigationRead.run(target: .id(birch.id), knownEntities: [atlas],
        resolve: { _ in Issue.record("an ID must not be re-resolved by name"); return [] },
        read: { id in #expect(id == birch.id); return mismatched ? fixtureDossier(atlas) : nil }, isCurrent: { true })
    if mismatched {
        guard case .failed = outcome else { Issue.record("wrong entity was accepted"); return }
    } else {
        guard case .notFound = outcome else { Issue.record("nil dossier was accepted as completion"); return }
    }
}

@Test("an obsolete entity request performs no resolution or dossier reads")
@MainActor func entityNavigationObsoleteBeforeRead() async {
    var calls = 0
    let outcome = await EntityNavigationRead.run(target: .name("alias"), knownEntities: [],
        resolve: { _ in calls += 1; return [birch] },
        read: { _ in calls += 1; return fixtureDossier(birch) }, isCurrent: { false })
    guard case .discarded = outcome else { Issue.record("obsolete request was published"); return }
    #expect(calls == 0)
}

@Test("entity navigation rechecks ownership after alias lookup before reading a dossier")
@MainActor func entityNavigationObsoleteAfterResolution() async {
    var current = true, reads = 0
    let outcome = await EntityNavigationRead.run(target: .name("alias"), knownEntities: [],
        resolve: { _ in await Task.yield(); current = false; return [birch] },
        read: { _ in reads += 1; return fixtureDossier(birch) }, isCurrent: { current })
    guard case .discarded = outcome else { Issue.record("obsolete resolution was published"); return }
    #expect(reads == 0)
}

// The bug: the chip claimed a successful load before any read had finished. A suspended read
// cannot produce completion, and cancellation/supersession while suspended cannot produce it later.
@Test("entity completion waits for its read and discards superseded or cancelled replies", arguments: ["complete", "supersede", "cancel"])
@MainActor func entityNavigationSuspendedRead(mode: String) async {
    let gate = NavigationReadGate()
    var current = true, finished = false
    let task = Task { @MainActor in
        let outcome = await EntityNavigationRead.run(target: .id(birch.id), knownEntities: [],
            resolve: { _ in [] }, read: { _ in await gate.read() }, isCurrent: { current })
        finished = true
        return outcome
    }
    await gate.waitForRead()
    #expect(!finished)
    if mode == "supersede" { current = false }
    if mode == "cancel" { task.cancel() }
    gate.release(fixtureDossier(birch))
    let outcome = await task.value
    if mode == "complete" {
        guard case .loaded(let dossier) = outcome else { Issue.record("current completed read was lost"); return }
        #expect(dossier.entity.id == birch.id)
    } else {
        guard case .discarded = outcome else { Issue.record("obsolete/cancelled read was published"); return }
    }
}

@Test("obsolete errors and explicit cancellation cannot become entity navigation failures", arguments: [false, true])
@MainActor func entityNavigationDiscardedError(cancel: Bool) async {
    var current = true
    let outcome = await EntityNavigationRead.run(target: .id(birch.id), knownEntities: [],
        resolve: { _ in [] }, read: { _ in
            if cancel { throw CancellationError() }
            current = false
            throw NavigationFixtureError()
        }, isCurrent: { current })
    guard case .discarded = outcome else { Issue.record("obsolete error was published"); return }
}
#endif
