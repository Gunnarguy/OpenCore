import Foundation

public enum QueryClass: String, Sendable, Codable, CaseIterable {
    case factual      // "What is OpenClinic built with?"
    case temporal     // "What was I doing in March?"
    case causal       // "Why did I replace Pinecone?"
    case analytical   // "What patterns run through my projects?"
    case differential // "What changed this week?"
    case epistemic    // "What do you believe about my work, and why?"

    /// Which retrieval signals matter for this shape of question. Fixed weights across all
    /// query types is the thing that makes hybrid search feel arbitrary; these are still
    /// hand-set rather than tuned, and are labelled as such in `Docs/RETRIEVAL.md`.
    public var weights: RetrievalWeights {
        switch self {
        case .factual:      RetrievalWeights(lexical: 0.45, semantic: 0.25, graph: 0.10, temporal: 0.00, authority: 0.20)
        case .temporal:     RetrievalWeights(lexical: 0.15, semantic: 0.20, graph: 0.10, temporal: 0.45, authority: 0.10)
        case .causal:       RetrievalWeights(lexical: 0.20, semantic: 0.25, graph: 0.30, temporal: 0.15, authority: 0.10)
        case .analytical:   RetrievalWeights(lexical: 0.10, semantic: 0.40, graph: 0.35, temporal: 0.05, authority: 0.10)
        case .differential: RetrievalWeights(lexical: 0.15, semantic: 0.15, graph: 0.10, temporal: 0.50, authority: 0.10)
        case .epistemic:    RetrievalWeights(lexical: 0.15, semantic: 0.25, graph: 0.25, temporal: 0.10, authority: 0.25)
        }
    }
}

public struct RetrievalWeights: Hashable, Sendable, Codable {
    public var lexical: Double
    public var semantic: Double
    public var graph: Double
    public var temporal: Double
    public var authority: Double

    public init(lexical: Double, semantic: Double, graph: Double, temporal: Double, authority: Double) {
        self.lexical = lexical
        self.semantic = semantic
        self.graph = graph
        self.temporal = temporal
        self.authority = authority
    }
}

/// One measured step of answering. Counters are recorded as the stage runs, never
/// reconstructed afterwards from what the answer looks like.
public struct ReceiptStage: Hashable, Sendable, Codable {
    public var name: String
    public var counters: [String: Int]
    public var milliseconds: Int
    public var note: String?

    public init(name: String, counters: [String: Int] = [:], milliseconds: Int, note: String? = nil) {
        self.name = name
        self.counters = counters
        self.milliseconds = milliseconds
        self.note = note
    }
}

/// What actually happened while answering one question.
///
/// The rule that makes this worth having: every field is *observed during execution*. If a
/// value could not be measured it is `nil` and renders as "not measured", never as a
/// plausible default. A receipt that guesses is worse than no receipt, because it looks
/// like proof.
public struct Receipt: Hashable, Sendable, Codable, Identifiable {
    public var id: ReceiptID
    public var query: String
    public var queryClass: QueryClass
    public var domainsAdmitted: [Domain]
    public var domainsBlocked: [Domain]
    public var stages: [ReceiptStage]
    public var objectsSearched: Int
    public var objectsRetrieved: Int
    public var evidenceAdmitted: Int
    public var claimsConsulted: Int
    public var contradictionsSurfaced: Int
    /// Which model wrote the prose, if any. `nil` means the answer was assembled
    /// deterministically from claims and no model ran.
    public var model: String?
    /// Objects whose text left the device. `0` unless a cloud model was used.
    public var objectsTransmitted: Int
    /// Set only when a calibrated confidence exists. `nil` renders as "not measured".
    public var confidence: Double?
    public var createdAt: Date

    public init(
        query: String,
        queryClass: QueryClass,
        domainsAdmitted: [Domain],
        domainsBlocked: [Domain],
        stages: [ReceiptStage],
        objectsSearched: Int,
        objectsRetrieved: Int,
        evidenceAdmitted: Int,
        claimsConsulted: Int,
        contradictionsSurfaced: Int,
        model: String?,
        objectsTransmitted: Int,
        confidence: Double?,
        createdAt: Date = Date()
    ) {
        self.id = ReceiptID.derived(from: query, String(Int(createdAt.timeIntervalSince1970 * 1000)))
        self.query = query
        self.queryClass = queryClass
        self.domainsAdmitted = domainsAdmitted
        self.domainsBlocked = domainsBlocked
        self.stages = stages
        self.objectsSearched = objectsSearched
        self.objectsRetrieved = objectsRetrieved
        self.evidenceAdmitted = evidenceAdmitted
        self.claimsConsulted = claimsConsulted
        self.contradictionsSurfaced = contradictionsSurfaced
        self.model = model
        self.objectsTransmitted = objectsTransmitted
        self.confidence = confidence
        self.createdAt = createdAt
    }

    /// Short human-readable handle, e.g. `oc_8f2a91`.
    public var shortCode: String { "oc_" + id.value.prefix(6) }
}

/// Accumulates a receipt while the query runs. An actor because stages are appended from
/// whichever task is doing the work.
public actor ReceiptRecorder {
    private var stages: [ReceiptStage] = []
    private var counters: [String: Int] = [:]

    public init() {}

    public func record<T>(_ name: String, note: String? = nil, _ body: () async throws -> (T, [String: Int])) async rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let (value, stageCounters) = try await body()
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        stages.append(ReceiptStage(name: name, counters: stageCounters, milliseconds: elapsed, note: note))
        for (key, count) in stageCounters { counters[key, default: 0] += count }
        return value
    }

    public func counter(_ key: String) -> Int { counters[key] ?? 0 }
    public func allStages() -> [ReceiptStage] { stages }
}
