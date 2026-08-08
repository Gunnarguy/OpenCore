import CoreGraph
import CoreJSONRPC
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation

/// OpenCore as MCP infrastructure.
///
/// This is the point where OpenCore stops being an app you look at and becomes something
/// other tools ask. Claude, or any MCP client, gets `core_ask` and `core_trace` and can
/// therefore cite *your* history back to the commit it came from.
///
/// **The boundary that matters:** an MCP caller is not you. Locally, naming a sensitive
/// domain in a query opens it, because a person typing "what did my doctor say" is giving
/// consent by asking. Over MCP the query text is written by a model, and a model asking
/// about your diagnosis is not consent. So `sensitiveDomainsUnlockable` defaults to false
/// and no wording in a tool call can reach medical, financial, or relationship data. The
/// receipt records the block either way, so an MCP-driven answer shows exactly what it
/// could not see.
public actor MCPServer {
    public static let protocolVersion = "2025-11-25"
    public static let serverVersion = "0.2.0"

    private let store: Store
    private let search: PassageSearch
    private let reasoner: Reasoner
    private let sensitiveDomainsUnlockable: Bool
    private var initialized = false

    public init(
        store: Store,
        embedder: (any EmbeddingProvider)? = nil,
        sensitiveDomainsUnlockable: Bool = false
    ) {
        self.store = store
        self.search = PassageSearch(store: store, embedder: embedder)
        self.reasoner = Reasoner(store: store, search: HybridSearch(store: store))
        self.sensitiveDomainsUnlockable = sensitiveDomainsUnlockable
    }

    // MARK: - Run loop

    /// Read newline-delimited JSON-RPC from stdin, write responses to stdout.
    ///
    /// Nothing but MCP messages may ever reach stdout, per the transport spec. Every log
    /// line in this file goes to stderr for that reason, and a stray `print` anywhere in
    /// the call path would corrupt the stream.
    public func run() async {
        log("OpenCore MCP server ready, protocol \(Self.protocolVersion)")

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }

            let request: RPCRequest
            do {
                request = try JSONDecoder().decode(RPCRequest.self, from: data)
            } catch {
                log("could not decode message: \(error)")
                continue
            }

            if request.isNotification {
                handleNotification(request)
                continue
            }

            let id = request.id ?? .null
            let response: RPCResponse
            do {
                response = .success(id: id, result: try await handle(request))
            } catch let error as RPCError {
                response = .failure(id: id, error: error)
            } catch {
                response = .failure(id: id, error: .internalError("\(error)"))
            }
            write(response)
        }

        log("stdin closed, shutting down")
    }

    private func handleNotification(_ request: RPCRequest) {
        if request.method == "notifications/initialized" {
            initialized = true
            log("client completed initialization")
        }
    }

    private func handle(_ request: RPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            return initializeResult()
        case "ping":
            return .object([:])
        case "tools/list":
            return .object(["tools": .array(Self.toolDefinitions)])
        case "tools/call":
            return try await callTool(request.params)
        case "resources/list":
            return .object(["resources": .array([])])
        case "prompts/list":
            return .object(["prompts": .array([])])
        default:
            throw RPCError.methodNotFound(request.method)
        }
    }

    private func initializeResult() -> JSONValue {
        .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string("opencore"),
                "version": .string(Self.serverVersion),
            ]),
            "instructions": .string("""
            OpenCore is an evidence-native store of this user's own history: repositories, \
            commits, documents, notes, calendar and reminders.

            Every answer it returns is assembled from stored claims, each with evidence, an \
            authority tier, and both time axes. Prefer core_ask for questions and follow up \
            with core_trace to show the user exactly which sources produced an answer.

            Sensitive domains (medical, financial, relationship) are \
            \(sensitiveDomainsUnlockable ? "reachable when a query names them" : "not reachable through this server at all") \
            regardless of how a question is worded. Blocked domains are reported in every receipt.
            """),
        ])
    }

    // MARK: - Tools

    static let toolDefinitions: [JSONValue] = [
        tool(
            "core_ask",
            "Answer a question from the user's own history. Returns claims with their evidence, authority tier, and whether each was observed directly or inferred, plus a receipt id for tracing.",
            ["query": ("string", "The question, in natural language.")],
            required: ["query"]
        ),
        tool(
            "core_search",
            "Retrieve passages from the user's history. Use when you want raw source material rather than an assembled answer.",
            [
                "query": ("string", "What to search for."),
                "limit": ("number", "Maximum passages to return. Default 8."),
            ],
            required: ["query"]
        ),
        tool(
            "core_claims",
            "List what OpenCore currently believes about one entity: a project, person, technology, or organization.",
            ["entity": ("string", "Name of the entity, e.g. a repository or project name.")],
            required: ["entity"]
        ),
        tool(
            "core_contradictions",
            "List claims that could not both be true, and how each was settled. Unresolved ones are places the store knows it does not know.",
            ["unresolved_only": ("boolean", "Only conflicts with no winner. Default false.")],
            required: []
        ),
        tool(
            "core_changed",
            "What OpenCore learned or changed its mind about over a recent window.",
            ["days": ("number", "How far back to look. Default 30.")],
            required: []
        ),
        tool(
            "core_trace",
            "The exact evidence behind a previous answer, given its receipt code (e.g. oc_8f2a91).",
            ["receipt": ("string", "Receipt short code from a previous core_ask.")],
            required: ["receipt"]
        ),
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: (String, String)],
        required: [String]
    ) -> JSONValue {
        var schemaProperties: [String: JSONValue] = [:]
        for (key, value) in properties {
            schemaProperties[key] = .object(["type": .string(value.0), "description": .string(value.1)])
        }
        return .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(schemaProperties),
                "required": .array(required.map { .string($0) }),
            ]),
            // Every tool this server exposes is read-only: OpenCore answers questions and
            // never mutates on a caller's behalf. Declared because a client reviewing this
            // server deserves the signal — while remembering that a client must not *trust*
            // it. Our own client treats annotations as advisory and still requires an
            // explicit allowlist, which is the correct posture toward any server including
            // this one.
            "annotations": .object([
                "readOnlyHint": .bool(true),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(true),
                "openWorldHint": .bool(false),
            ]),
        ])
    }

    private func callTool(_ params: JSONValue?) async throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            throw RPCError.invalidParams("missing tool name")
        }
        let arguments = params?["arguments"] ?? .object([:])

        do {
            let text = switch name {
            case "core_ask": try await ask(arguments)
            case "core_search": try await searchPassages(arguments)
            case "core_claims": try await claims(arguments)
            case "core_contradictions": try await contradictions(arguments)
            case "core_changed": try await changed(arguments)
            case "core_trace": try await trace(arguments)
            default: throw RPCError.invalidParams("unknown tool: \(name)")
            }
            return Self.textResult(text)
        } catch let error as RPCError {
            throw error
        } catch {
            // Tool errors go back as isError content rather than as protocol errors, so
            // the model can read what went wrong and adjust instead of the call vanishing.
            return Self.textResult("Tool failed: \(error)", isError: true)
        }
    }

    private static func textResult(_ text: String, isError: Bool = false) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    // MARK: - Tool bodies

    private func ask(_ arguments: JSONValue) async throws -> String {
        guard let query = arguments["query"]?.stringValue else { throw RPCError.invalidParams("query is required") }

        let answer = try await reasoner.answer(query, externalCaller: !sensitiveDomainsUnlockable)
        var lines: [String] = []

        if let insufficient = answer.insufficientEvidence {
            lines.append("Not enough evidence to answer.")
            lines.append(insufficient)
        } else {
            lines.append(answer.summary)
            lines.append("")
            for point in answer.points.prefix(12) {
                lines.append("\(point.derivation == .observed ? "[observed]" : "[inferred]") \(point.statement)")
                lines.append("  confidence \(String(format: "%.2f", point.confidence)) · authority: \(point.authority.label)")
                for evidence in point.supporting.prefix(2) {
                    lines.append("  evidence: \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(180))")
                }
                for evidence in point.counter.prefix(2) {
                    lines.append("  COUNTER-EVIDENCE: \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(180))")
                }
            }
        }

        if !answer.contradictions.isEmpty {
            lines.append("")
            lines.append("Contradictions touching this answer:")
            for contradiction in answer.contradictions.prefix(5) {
                lines.append("  \(contradiction.kind.rawValue) → \(contradiction.resolution.rawValue): \(contradiction.reason)")
            }
        }

        let receipt = answer.receipt
        lines.append("")
        lines.append("--- receipt \(receipt.shortCode) ---")
        lines.append("objects searched: \(receipt.objectsSearched), retrieved: \(receipt.objectsRetrieved)")
        lines.append("claims consulted: \(receipt.claimsConsulted), evidence admitted: \(receipt.evidenceAdmitted)")
        lines.append("domains blocked: \(receipt.domainsBlocked.map(\.rawValue).joined(separator: ", "))")
        lines.append("confidence: \(receipt.confidence.map { String(format: "%.2f", $0) } ?? "not measured")")
        lines.append("Trace this with core_trace(receipt: \"\(receipt.shortCode)\").")
        return lines.joined(separator: "\n")
    }

    private func searchPassages(_ arguments: JSONValue) async throws -> String {
        guard let query = arguments["query"]?.stringValue else { throw RPCError.invalidParams("query is required") }
        let limit = arguments["limit"]?.intValue ?? 8

        let policy = try await policy(for: query)
        let outcome = try await search.search(
            query: query,
            queryClass: QueryClassifier().classify(query).queryClass,
            policy: policy,
            limit: limit
        )

        guard !outcome.hits.isEmpty else {
            return "No passages matched. \(outcome.chunksSearched) chunks searched, \(outcome.blockedByDomain) withheld by domain policy."
        }

        var lines = ["\(outcome.hits.count) passages from \(outcome.chunksSearched) chunks:"]
        for (index, hit) in outcome.hits.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(hit.object.title)  [\(hit.object.kind.rawValue), \(hit.object.authority.label)]")
            lines.append("   \(hit.chunk.text.replacingOccurrences(of: "\n", with: " ").prefix(400))")
            if let uri = hit.object.uri { lines.append("   \(uri)") }
        }
        for (signal, reason) in outcome.unavailableSignals.sorted(by: { $0.key < $1.key }) {
            lines.append("")
            lines.append("note — \(signal) unavailable: \(reason)")
        }
        return lines.joined(separator: "\n")
    }

    private func claims(_ arguments: JSONValue) async throws -> String {
        guard let name = arguments["entity"]?.stringValue else { throw RPCError.invalidParams("entity is required") }
        guard let entity = try await store.resolve(surface: name).first?.0 else {
            return "No entity known as '\(name)'."
        }
        guard try await policy(for: name).admits(entity.domain) else {
            return "'\(name)' is in the \(entity.domain.rawValue) domain, which this server does not expose."
        }

        let claims = try await store.claims(subject: entity.id)
        guard !claims.isEmpty else { return "\(entity.canonicalName) exists but has no current claims." }

        var lines = ["\(entity.canonicalName) (\(entity.kind.rawValue)):"]
        for claim in claims {
            let value: String = if let objectEntity = claim.objectEntity {
                try await store.entity(objectEntity)?.canonicalName ?? "?"
            } else {
                claim.literal ?? "?"
            }
            lines.append("  [\(claim.derivation.rawValue)] \(claim.predicate) → \(value)  (confidence \(String(format: "%.2f", claim.confidence)), \(claim.authority.label))")
        }
        return lines.joined(separator: "\n")
    }

    private func contradictions(_ arguments: JSONValue) async throws -> String {
        let unresolvedOnly = arguments["unresolved_only"]?.boolValue ?? false
        let items = try await store.contradictions(unresolvedOnly: unresolvedOnly)
        guard !items.isEmpty else { return unresolvedOnly ? "No unresolved contradictions." : "No contradictions detected." }

        var lines: [String] = []
        for item in items.prefix(30) {
            lines.append("\(item.kind.rawValue) → \(item.resolution.rawValue): \(item.reason)")
        }
        return lines.joined(separator: "\n")
    }

    private func changed(_ arguments: JSONValue) async throws -> String {
        let days = arguments["days"]?.intValue ?? 30
        let beliefs = try await store.beliefsDecided(since: Date().addingTimeInterval(-Double(days) * 86_400))
        guard !beliefs.isEmpty else { return "No belief changes in the last \(days) days." }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        for belief in beliefs.prefix(50) {
            guard let claim = try await store.claim(belief.claimID) else { continue }
            let subject = try await store.entity(claim.subject)?.canonicalName ?? "?"
            let value: String = if let objectEntity = claim.objectEntity {
                try await store.entity(objectEntity)?.canonicalName ?? "?"
            } else {
                claim.literal ?? "?"
            }
            lines.append("\(formatter.string(from: belief.decidedAt))  \(belief.version == 1 ? "LEARNED" : "UPDATED")  \(subject) \(claim.predicate) → \(value)  (\(belief.reason))")
        }
        return lines.isEmpty ? "No belief changes in the last \(days) days." : lines.joined(separator: "\n")
    }

    private func trace(_ arguments: JSONValue) async throws -> String {
        guard let code = arguments["receipt"]?.stringValue else { throw RPCError.invalidParams("receipt is required") }
        guard let receipt = try await store.receipt(code: code) else { return "No receipt matching '\(code)'." }

        let rows = try await store.trace(receipt: receipt.id)
        guard !rows.isEmpty else { return "Receipt \(receipt.shortCode) admitted no evidence." }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var lines = ["Evidence behind \(receipt.shortCode) — \"\(receipt.query)\":"]
        for (index, entry) in rows.enumerated() {
            let (evidence, object, score) = entry
            lines.append("")
            lines.append("\(index + 1). [\(String(format: "%.3f", score))] \(object.title)")
            lines.append("   \(object.kind.rawValue) · \(object.authority.label) · \(object.authoredAt.map(formatter.string(from:)) ?? "undated")")
            lines.append("   \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(300))")
            if let uri = object.uri { lines.append("   \(uri)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Policy

    private func policy(for query: String) async throws -> AdmissionPolicy {
        let (domain, requested) = AdmissionPolicy.classifyDomain(
            query,
            knownEntitySurfaces: try await store.aliasSurfaces()
        )
        // An external caller cannot unlock a sensitive domain by wording, and cannot land
        // in one either: a query that classifies as medical is re-based to project.
        if !sensitiveDomainsUnlockable {
            let safeDomain = domain.isSensitive ? Domain.project : domain
            return AdmissionPolicy(queryDomain: safeDomain, explicitlyRequested: [])
        }
        return AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested)
    }

    // MARK: - Transport

    private func write(_ response: RPCResponse) {
        guard let data = try? JSONEncoder().encode(response),
              var line = String(data: data, encoding: .utf8)
        else {
            log("could not encode response")
            return
        }
        // A message must not contain embedded newlines. Encoded JSON should not, but a
        // guard here is cheaper than a corrupted stream that presents as a client hang.
        line = line.replacingOccurrences(of: "\n", with: " ")
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("[opencore-mcp] \(message)\n".utf8))
    }
}
