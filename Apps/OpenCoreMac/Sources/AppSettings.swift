import CoreModel
import CoreSearch
import Foundation
import Observation

/// App preferences, in `UserDefaults`.
///
/// Deliberately **not** in the SQLite store. That file is the user's data — objects, claims,
/// receipts — and it is the thing they export, back up, and hand to another machine. Mixing
/// "how big should chunks be" into it would make a preference travel with a dataset, which is
/// wrong in both directions: an export would carry settings nobody asked for, and a fresh
/// install would inherit tuning from whoever produced the file.
@MainActor
@Observable
final class AppSettings {
    // MARK: - Retrieval

    var rrfK: Double { didSet { save(rrfK, "retrieval.rrfK") } }
    var mmrLambda: Double { didSet { save(mmrLambda, "retrieval.mmrLambda") } }
    var candidatesPerLeg: Int { didSet { save(candidatesPerLeg, "retrieval.candidatesPerLeg") } }
    var signalScale: Double { didSet { save(signalScale, "retrieval.signalScale") } }
    var passageLimit: Int { didSet { save(passageLimit, "retrieval.passageLimit") } }
    var expandContext: Bool { didSet { save(expandContext, "retrieval.expandContext") } }

    var tuning: RetrievalTuning {
        RetrievalTuning(rrfK: rrfK, mmrLambda: mmrLambda, candidatesPerLeg: candidatesPerLeg, signalScale: signalScale)
    }

    // MARK: - Chunking
    //
    // Separate from retrieval because these are the only settings that invalidate data on
    // disk. Changing them requires re-chunking every object and re-embedding every passage,
    // so the UI has to say so rather than quietly leaving the store inconsistent with them.

    var chunkTargetSize: Int { didSet { save(chunkTargetSize, "chunking.targetSize") } }
    var chunkOverlap: Int { didSet { save(chunkOverlap, "chunking.overlap") } }

    var chunker: Chunker { Chunker(targetSize: chunkTargetSize, overlap: chunkOverlap) }

    /// True when chunking settings no longer match what the stored passages were built with.
    /// Set after a change, cleared by a rebuild.
    var chunkingDirty: Bool { didSet { save(chunkingDirty, "chunking.dirty") } }

    // MARK: - Sync

    var githubCommitsPerRepo: Int { didSet { save(githubCommitsPerRepo, "sync.githubCommits") } }
    var githubIncludeForks: Bool { didSet { save(githubIncludeForks, "sync.githubForks") } }
    var calendarLookBackDays: Int { didSet { save(calendarLookBackDays, "sync.calendarBack") } }
    var calendarLookAheadDays: Int { didSet { save(calendarLookAheadDays, "sync.calendarAhead") } }

    // MARK: - MCP server

    /// Whether the MCP server this app ships lets a caller reach medical, financial or
    /// relationship data. Off, and it takes a deliberate act to change, because the query text
    /// reaching that server is written by a model and a model asking about your diagnosis is
    /// not consent.
    var mcpExposeSensitiveDomains: Bool { didSet { save(mcpExposeSensitiveDomains, "mcp.exposeSensitive") } }

    // MARK: - Defaults

    static let defaultChunkTargetSize = 1200
    static let defaultChunkOverlap = 150

    var retrievalIsDefault: Bool {
        tuning.isDefault && passageLimit == 8 && expandContext
    }

    var chunkingIsDefault: Bool {
        chunkTargetSize == Self.defaultChunkTargetSize && chunkOverlap == Self.defaultChunkOverlap
    }

    func resetRetrieval() {
        let base = RetrievalTuning.default
        rrfK = base.rrfK
        mmrLambda = base.mmrLambda
        candidatesPerLeg = base.candidatesPerLeg
        signalScale = base.signalScale
        passageLimit = 8
        expandContext = true
    }

    func resetChunking() {
        chunkTargetSize = Self.defaultChunkTargetSize
        chunkOverlap = Self.defaultChunkOverlap
    }

    // MARK: - Storage

    private let defaults = UserDefaults.standard

    init() {
        let base = RetrievalTuning.default
        // A local, not `self.defaults`: Swift will not let a stored property be read before
        // every one of them is initialized, and these run during that window.
        let store = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double {
            store.object(forKey: key) as? Double ?? fallback
        }
        func integer(_ key: String, _ fallback: Int) -> Int {
            store.object(forKey: key) as? Int ?? fallback
        }
        func boolean(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) as? Bool ?? fallback
        }

        rrfK = double("retrieval.rrfK", base.rrfK)
        mmrLambda = double("retrieval.mmrLambda", base.mmrLambda)
        candidatesPerLeg = integer("retrieval.candidatesPerLeg", base.candidatesPerLeg)
        signalScale = double("retrieval.signalScale", base.signalScale)
        passageLimit = integer("retrieval.passageLimit", 8)
        expandContext = boolean("retrieval.expandContext", true)

        chunkTargetSize = integer("chunking.targetSize", Self.defaultChunkTargetSize)
        chunkOverlap = integer("chunking.overlap", Self.defaultChunkOverlap)
        chunkingDirty = boolean("chunking.dirty", false)

        githubCommitsPerRepo = integer("sync.githubCommits", 100)
        githubIncludeForks = boolean("sync.githubForks", false)
        calendarLookBackDays = integer("sync.calendarBack", 730)
        calendarLookAheadDays = integer("sync.calendarAhead", 180)

        mcpExposeSensitiveDomains = boolean("mcp.exposeSensitive", false)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
