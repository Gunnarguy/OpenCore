import CoreGraph
import CoreJSONRPC
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import CoreTelemetry
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
    private let currentDate: @Sendable () -> Date
    private let currentCalendar: @Sendable () -> Calendar
    private var initialized = false

    /// - Parameters:
    ///   - now: read for each call, never kept. This process lives for days inside a client, so
    ///     a stored date measures "recently" from when the server started.
    ///   - calendar: read for each call too, so a change of time zone reaches an open session.
    public init(
        store: Store,
        embedder: (any EmbeddingProvider)? = nil,
        sensitiveDomainsUnlockable: Bool = false,
        now: @autoclosure @escaping @Sendable () -> Date = Date(),
        calendar: @autoclosure @escaping @Sendable () -> Calendar = .current
    ) {
        self.store = store
        self.search = PassageSearch(store: store, embedder: embedder)
        // Same passage-level engine the app and CLI use, so an MCP caller and a human
        // asking the same question get the same retrieval rather than two different ones.
        self.reasoner = Reasoner(store: store, search: PassageSearch(store: store, embedder: embedder), now: now(), calendar: calendar())
        self.sensitiveDomainsUnlockable = sensitiveDomainsUnlockable
        self.currentDate = now
        self.currentCalendar = calendar
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
                request = try RPCRequest.decode(data)
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

    /// Spans recorded here are held in memory and rendered only by `log`, which writes to
    /// stderr. Telemetry has no stdout sink at all, so instrumenting the server's own request
    /// path cannot corrupt the JSON-RPC stream.
    public func handle(_ request: RPCRequest) async throws -> JSONValue {
        try await Telemetry.span("mcp \(request.method)", .mcp) { scope in
            scope.attribute("notification", String(request.isNotification))
            switch request.method {
            case "initialize":
                return initializeResult(request.params)
            case "ping":
                return .object([:])
            case "tools/list":
                scope.set("tools", Self.toolDefinitions.count)
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
    }

    /// Versions this server can genuinely serve, newest first.
    ///
    /// Honest rather than generous. This is a **tools-only** server: no sampling, roots,
    /// logging, elicitation or resources. Across these three revisions the `initialize`,
    /// `tools/list` and `tools/call` shapes it actually implements are identical, and every
    /// difference between them lands in features it does not offer. So it can serve all three
    /// truthfully. `2026-07-28` is deliberately absent: that one removes the handshake and
    /// changes result shapes, and claiming it without implementing it is the half-migration
    /// `.claude/rules/mcp.md` forbids.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    /// Reply with the client's requested version when it is one we can speak.
    ///
    /// The previous version answered `2025-11-25` to every `initialize` no matter what was
    /// asked for. The spec says a client that receives a version it does not support should
    /// disconnect, so a hardcoded reply turns "one spec behind" into "silently fails to
    /// connect", and the symptom is a client that lists no tools with nothing in any log.
    /// The version to answer `initialize` with, given what the client asked for.
    ///
    /// Separated from the response body so it can be tested without standing up a store.
    static func negotiatedProtocolVersion(requested: String?) -> String {
        guard let requested, supportedProtocolVersions.contains(requested) else { return protocolVersion }
        return requested
    }

    private func initializeResult(_ params: JSONValue?) -> JSONValue {
        let requested = params?.objectValue?["protocolVersion"]?.stringValue
        let agreed = Self.negotiatedProtocolVersion(requested: requested)
        log("client requested protocol \(requested ?? "none"), answering \(agreed)")
        return .object([
            "protocolVersion": .string(agreed),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string("opencore"),
                "version": .string(Self.serverVersion),
            ]),
            "instructions": .string("""
            OpenCore is an evidence-native store of this user's own history. Through this \
            server it answers from repositories, commits and documents. Notes, calendar and \
            reminders are personal and are not reachable here.

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

    public static let toolDefinitions: [JSONValue] = [
        tool(
            "core_ask",
            "Answer a question from the user's own history. Returns claims with their evidence, authority tier, and whether each was observed directly or inferred, the passages that matched, and a receipt id for tracing. A time phrase such as 'recently', 'last week', 'in March' or 'since August' filters the answer to that window, reports what happened in it, and states the days read and how fresh the store is. Read a 'Stale:' line as missing data, not as a quiet period.",
            [
                "query": ("string", "The question, in natural language."),
                "as_of": ("string", "Optional YYYY-MM-DD or ISO-8601 instant to evaluate what held and was believed at that time."),
                "synthesize": ("boolean", "Optional. When true, also runs on-device /usr/bin/fm grounded synthesis over admitted passages with [1]..[N] citations."),
            ],
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
            [
                "entity": ("string", "Name of the entity, e.g. a repository or project name."),
                "as_of": ("string", "Optional YYYY-MM-DD or ISO-8601 instant to evaluate bitemporal validity."),
            ],
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
        tool(
            "core_dossier",
            "Complete dossier for one entity (project, person, technology, or organization): aliases, current beliefs, contradictions, and timeline events.",
            ["entity": ("string", "Name of the entity, e.g. a repository or project name.")],
            required: ["entity"]
        ),
        tool(
            "core_timeline",
            "Chronological stream of events (commits, files, and whatever else the domain policy admits) over a recent window. Calendar entries and notes are personal, so this server does not return them.",
            [
                "days": ("number", "How far back to look in days. Default 30."),
                "entity": ("string", "Optional entity name to filter events to a single subject."),
            ],
            required: []
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
            // server deserves the signal, while remembering that a client must not *trust*
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
            case "core_dossier": try await dossier(arguments)
            case "core_timeline": try await timeline(arguments)
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

    private static func parseInstant(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let iso = ISO8601DateFormatter().date(from: text) { return iso }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(secondsFromGMT: 0)
        return day.date(from: text)
    }

    /// A bad `as_of` is refused. Reading it as absent answered with today's data under a
    /// question that asked about another date, and said nothing about it.
    private static func requireInstant(_ text: String?) throws -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let instant = parseInstant(text) else {
            throw RPCError.invalidParams("as_of must be YYYY-MM-DD or ISO-8601, got '\(text.prefix(40))'")
        }
        return instant
    }

    private func ask(_ arguments: JSONValue) async throws -> String {
        guard let query = arguments["query"]?.stringValue else { throw RPCError.invalidParams("query is required") }
        let instant = try Self.requireInstant(arguments["as_of"]?.stringValue)

        let answer = try await reasoner.answer(
            query,
            externalCaller: !sensitiveDomainsUnlockable,
            asOfWorld: instant,
            asOfKnowledge: instant
        )
        var lines: [String] = []

        if let counted = answer.counted {
            // Said explicitly, because the calling model is about to decide how far to trust
            // this. A count carries no cited passages BY CONSTRUCTION, and a model that reads
            // "0 evidence admitted" without this line will reasonably conclude the answer is
            // unsupported and hedge, or worse, go looking for passages to "confirm" it and
            // report whatever the top six happen to say. That is the original defect.
            lines.append(counted.sentence)
            lines.append("")
            lines.append("This is a computed count, not a summary of retrieved passages: it was "
                + "produced by counting every \(counted.breakdown.kind.rawValue) row the domain "
                + "policy admits. There are no passages to cite and none were read. It is exact "
                + "over the admitted rows, so do not qualify it with 'approximately' or check it "
                + "against a search.")
            if counted.breakdown.unclassified > 0 {
                lines.append("\(counted.breakdown.unclassified) row(s) recorded no "
                    + "\(counted.breakdown.key) and are unaccounted for rather than counted as "
                    + "not matching. Do not treat them as a zero.")
            }
        } else if let insufficient = answer.insufficientEvidence {
            lines.append("Not enough evidence to answer.")
            lines.append(insufficient)
        } else {
            lines.append(answer.summary)
            if let activity = answer.activity, activity.totalEvents > 0 {
                lines.append("")
                lines.append("Activity in this window (computed from the event log, not retrieved passages):")
                for group in activity.groups {
                    let upkeep = group.upkeep > 0 ? " and \(group.upkeep) upkeep" : ""
                    lines.append("- \(group.subject.canonicalName): \(group.events) \(group.verb)\(upkeep), latest \(Self.day(group.lastAt))")
                    for event in group.latest {
                        lines.append("    \(Self.day(event.occurredAt))  \(event.detail.replacingOccurrences(of: "\n", with: " ").prefix(120))")
                    }
                }
            }
            if !answer.points.isEmpty {
                lines.append("")
            }
            for point in answer.points.prefix(Self.pointsShown) {
                lines.append("\(point.derivation == .observed ? "[observed]" : "[inferred]") \(point.statement)")
                lines.append("  confidence \(String(format: "%.2f", point.confidence)) · authority: \(point.authority.label)")
                for evidence in point.supporting.prefix(2) {
                    lines.append("  evidence: \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(180))")
                }
                for evidence in point.counter.prefix(2) {
                    lines.append("  COUNTER-EVIDENCE: \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(180))")
                }
            }
            if answer.points.count > Self.pointsShown {
                lines.append("(\(Self.pointsShown) of \(answer.points.count) claims shown, most relevant first.)")
            }
            // A claim says what the store concluded. A passage shows the text, including for
            // sources that produce no claims at all. This list used to be dropped here, so
            // the matched text never reached the caller and core_ask returned only whatever
            // twelve claims survived the cut.
            if !answer.passages.isEmpty {
                lines.append("")
                lines.append("Matching passages:")
                for hit in answer.passages.prefix(Self.passagesShown) {
                    let date = hit.object.authoredAt.map { " · \(Self.day($0))" } ?? ""
                    lines.append("- \(hit.object.title) [\(hit.object.kind.rawValue)\(date)]")
                    lines.append("    \(hit.chunk.text.replacingOccurrences(of: "\n", with: " ").prefix(240))")
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

        if arguments["synthesize"]?.boolValue == true, answer.counted == nil {
            let activePolicy = try await policy(for: query)
            // The same text and the same window as the answer above it. Searching the whole
            // question here summarised passages from any year under an answer about last week.
            let passageOutcome = try await search.search(
                query: answer.searchedText ?? query,
                queryClass: answer.receipt.queryClass,
                policy: activePolicy,
                limit: 5,
                window: answer.window?.interval
            )
            var sources: [GroundingSource] = []
            for hit in passageOutcome.hits {
                sources.append(GroundingSource(
                    index: sources.count + 1,
                    title: hit.object.title,
                    text: hit.chunk.text,
                    objectID: hit.object.id,
                    authority: hit.object.authority,
                    uri: hit.object.uri
                ))
            }
            if let brief = await Conversation.synthesizeGroundedBrief(question: query, sources: sources) {
                lines.append("")
                lines.append("Supplemental passage summary (\(brief.modelName)); separate retrieval, no persisted receipt:")
                lines.append("  \(brief.text)")
                for src in brief.sources {
                    lines.append("  [\(src.index)] \(src.title) (\(src.authority.label)); object: \(src.objectID.value); uri: \(src.uri ?? "none")")
                }
            }
        }

        let receipt = answer.receipt
        lines.append("")
        lines.append("--- receipt \(receipt.shortCode) ---")
        lines.append("Receipt scope: the deterministic claim answer; any supplemental summary has separate retrieval and no persisted receipt.")
        lines.append("objects searched: \(receipt.objectsSearched), retrieved: \(receipt.objectsRetrieved)")
        lines.append("claims consulted: \(receipt.claimsConsulted), evidence admitted: \(receipt.evidenceAdmitted)")
        lines.append("domains blocked: \(receipt.domainsBlocked.map(\.rawValue).joined(separator: ", "))")
        lines.append("confidence: \(receipt.confidence.map { String(format: "%.2f", $0) } ?? "not measured")")
        lines.append(receipt.outboundDescription)
        lines.append("Trace this with core_trace(receipt: \"\(receipt.shortCode)\").")
        return lines.joined(separator: "\n")
    }

    /// How many passages `core_ask` prints. **Chosen, not measured:** enough to show the text
    /// behind an answer without repeating `core_search`.
    private static let passagesShown = 5

    /// How many claims `core_ask` prints. **Chosen, not measured.** The answer's ordering is
    /// what makes a cut safe, so the question's own line is above it.
    private static let pointsShown = 12

    /// Tool arguments come from a model, so a limit is clamped rather than trusted. 50 is a
    /// chosen ceiling on one reply's size.
    private static func boundedLimit(_ value: JSONValue?, default fallback: Int) -> Int {
        min(max(1, value?.intValue ?? fallback), 50)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func searchPassages(_ arguments: JSONValue) async throws -> String {
        guard let query = arguments["query"]?.stringValue else { throw RPCError.invalidParams("query is required") }
        let limit = Self.boundedLimit(arguments["limit"], default: 8)

        let policy = try await policy(for: query)
        let calendar = currentCalendar()
        let window = TemporalIntent.window(in: query, now: currentDate(), calendar: calendar)
        let searchText = window?.searchText ?? query
        let outcome = try await search.search(
            query: searchText,
            queryClass: QueryClassifier().classify(query).queryClass,
            policy: policy,
            limit: limit,
            window: window?.interval,
            // See `Reasoner.answer`: a blocked count is an existence oracle for a model.
            reportBlocked: sensitiveDomainsUnlockable
        )
        var report: String?
        if let window {
            report = try await store.windowReport(window, domains: policy.admitted, calendar: calendar).text
        }

        guard !outcome.hits.isEmpty else {
            let withheld = sensitiveDomainsUnlockable ? ", \(outcome.blockedByDomain) withheld by domain policy" : ""
            // Said, because "no passages" under a Window line reads as a quiet stretch.
            let empty = window != nil && searchText.isEmpty
                ? "Nothing to search for: this question names a span and no topic, so no passage was read. core_ask answers it from the event log."
                : "No passages matched. \(outcome.chunksSearched) chunks searched\(withheld)."
            return report.map { "\(empty)\n\($0)" } ?? empty
        }

        var lines = ["\(outcome.hits.count) passages from \(outcome.chunksSearched) chunks:"]
        if let report { lines.append(report) }
        for (index, hit) in outcome.hits.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(hit.object.title)  [\(hit.object.kind.rawValue), \(hit.object.authority.label)]")
            lines.append("   \(hit.chunk.text.replacingOccurrences(of: "\n", with: " ").prefix(400))")
            if let uri = hit.object.uri { lines.append("   \(uri)") }
        }
        for (signal, reason) in outcome.unavailableSignals.sorted(by: { $0.key < $1.key }) {
            lines.append("")
            lines.append("note: \(signal) unavailable: \(reason)")
        }
        return lines.joined(separator: "\n")
    }

    private func claims(_ arguments: JSONValue) async throws -> String {
        guard let name = arguments["entity"]?.stringValue else { throw RPCError.invalidParams("entity is required") }
        guard let entity = try await resolveEntityForCaller(name) else {
            return "No entity known as '\(name)'."
        }
        let activePolicy = try await policy(for: name)
        guard activePolicy.admits(entity.domain) else {
            return "'\(name)' is in the \(entity.domain.rawValue) domain, which this server does not expose."
        }

        let instant = try Self.requireInstant(arguments["as_of"]?.stringValue)
        let rawClaims = try await store.claims(
            subject: entity.id,
            currentOnly: instant == nil,
            asOfWorld: instant,
            asOfKnowledge: instant
        )
        var claims: [CoreClaim] = []
        for claim in rawClaims {
            guard try await ClaimAdmission.admits(claim, policy: activePolicy, store: store) else { continue }
            claims.append(claim)
        }
        guard !claims.isEmpty else { return "\(entity.canonicalName) exists but has no current claims." }

        // One line per fact, as `core_ask` and `core_dossier` have. A push mints a new row for an
        // unchanged value, so `status → active` printed once per push. The strongest row speaks
        // for the group, and the count says how many there were.
        var rows: [(claim: CoreClaim, value: String, occurrences: Int)] = []
        var rowForFact: [String: Int] = [:]
        for claim in claims {
            let value: String = if let objectEntity = claim.objectEntity {
                try await store.entity(objectEntity)?.canonicalName ?? "?"
            } else {
                claim.literal ?? "?"
            }
            let fact = "\(claim.predicate)|\(value)"
            guard let index = rowForFact[fact] else {
                rowForFact[fact] = rows.count
                rows.append((claim, value, 1))
                continue
            }
            rows[index].occurrences += 1
            if (claim.authority.rawValue, claim.confidence) > (rows[index].claim.authority.rawValue, rows[index].claim.confidence) {
                rows[index].claim = claim
            }
        }

        var lines = ["\(entity.canonicalName) (\(entity.kind.rawValue)):"]
        var printedHistoryKeys: Set<String> = []
        for (claim, value, occurrences) in rows {
            let repeated = occurrences > 1 ? " ×\(occurrences)" : ""
            lines.append("  [\(claim.derivation.rawValue)] \(claim.predicate) → \(value)\(repeated)  (confidence \(String(format: "%.2f", claim.confidence)), \(claim.authority.label))")
            if printedHistoryKeys.insert(claim.claimKey).inserted {
                let rawHistory = try await store.beliefHistory(key: claim.claimKey)
                var history: [Belief] = []
                for belief in rawHistory {
                    guard let beliefClaim = try await store.claim(belief.claimID),
                          try await ClaimAdmission.admits(beliefClaim, policy: activePolicy, store: store)
                    else { continue }
                    history.append(belief)
                }
                if history.count > 1 {
                    for belief in history {
                        lines.append("    v\(belief.version): \(try await admittedReason(belief, policy: activePolicy))")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func contradictions(_ arguments: JSONValue) async throws -> String {
        let unresolvedOnly = arguments["unresolved_only"]?.boolValue ?? false
        let activePolicy = try await policy(for: "")
        let rawItems = try await store.contradictions(unresolvedOnly: unresolvedOnly)
        var items: [Contradiction] = []
        for item in rawItems {
            guard let claimA = try await store.claim(item.claimA),
                  let claimB = try await store.claim(item.claimB),
                  try await ClaimAdmission.admits(claimA, policy: activePolicy, store: store),
                  try await ClaimAdmission.admits(claimB, policy: activePolicy, store: store)
            else { continue }
            items.append(item)
        }
        guard !items.isEmpty else { return unresolvedOnly ? "No unresolved contradictions." : "No contradictions detected." }

        var lines: [String] = []
        for item in items.prefix(30) {
            lines.append("\(item.kind.rawValue) → \(item.resolution.rawValue): \(item.reason)")
        }
        return lines.joined(separator: "\n")
    }

    private func changed(_ arguments: JSONValue) async throws -> String {
        let days = min(max(1, arguments["days"]?.intValue ?? 30), 36_500)
        let activePolicy = try await policy(for: "")
        let beliefs = try await store.beliefsDecided(since: Date().addingTimeInterval(-Double(days) * 86_400))
        guard !beliefs.isEmpty else { return "No belief changes in the last \(days) days." }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        for belief in beliefs {
            guard lines.count < 50 else { break }
            guard let claim = try await store.claim(belief.claimID),
                  try await ClaimAdmission.admits(claim, policy: activePolicy, store: store),
                  let subjectEntity = try await store.entity(claim.subject)
            else { continue }
            let value: String = if let objectEntity = claim.objectEntity {
                try await store.entity(objectEntity)?.canonicalName ?? "?"
            } else {
                claim.literal ?? "?"
            }
            lines.append("\(formatter.string(from: belief.decidedAt))  \(belief.version == 1 ? "LEARNED" : "UPDATED")  \(subjectEntity.canonicalName) \(claim.predicate) → \(value)  (\(try await admittedReason(belief, policy: activePolicy)))")
        }
        return lines.isEmpty ? "No belief changes in the last \(days) days." : lines.joined(separator: "\n")
    }

    private func trace(_ arguments: JSONValue) async throws -> String {
        guard let code = arguments["receipt"]?.stringValue else { throw RPCError.invalidParams("receipt is required") }
        guard let receipt = try await store.receipt(code: code) else { return "No receipt matching '\(code)'." }

        let activePolicy = try await policy(for: receipt.query)
        if let blockedDomain = receipt.domainsAdmitted.first(where: { !activePolicy.admits($0) }) {
            return "Receipt \(receipt.shortCode) is in the \(blockedDomain.rawValue) domain, which this server does not expose."
        }

        return try await traceRows(receipt, policy: activePolicy) + "\n" + receipt.outboundDescription
    }

    private func traceRows(_ receipt: Receipt, policy activePolicy: AdmissionPolicy) async throws -> String {
        let rows = try await store.trace(receipt: receipt.id)
            .filter { activePolicy.admits($0.1.domain) }
        guard !rows.isEmpty else {
            // A counted answer has no evidence rows BY CONSTRUCTION, and saying only "admitted
            // no evidence" reads as a failed lookup. The distinction is the whole point of
            // trace: one of these is an answer with nothing behind it, the other is an answer
            // whose support is the query itself.
            if receipt.queryClass == .aggregate {
                return "Receipt \(receipt.shortCode) is a computed count over "
                    + "\(receipt.objectsSearched) admitted rows, so it cites no evidence and none "
                    + "was read. Its support is the count itself, not a set of passages."
            }
            // Same reasoning for a time question, whose support is the event log.
            if let stage = receipt.stages.first(where: { $0.name == "activity" }) {
                return "Receipt \(receipt.shortCode) was answered from \(stage.counters["events_in_window"] ?? 0) "
                    + "event(s) in the recorded window, so it cites no evidence rows. "
                    + "Its support is the event log, not a set of passages."
            }
            // Chat answering from passages alone. "Admitted no evidence" beside a counter of six
            // is the contradiction `Receipt.answeredFromClaims` exists to prevent.
            if !receipt.answeredFromClaims, receipt.evidenceAdmitted > 0 {
                return "Receipt \(receipt.shortCode) was answered from \(receipt.evidenceAdmitted) passage(s) "
                    + "and read no claims, so it has no evidence rows to trace."
            }
            return "Receipt \(receipt.shortCode) admitted no evidence."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // Raw owner questions and stage notes have no independent domain label. A trace may
        // expose admitted source evidence without exposing that unrelated private free text.
        var lines = ["Evidence behind \(receipt.shortCode):"]
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

    private func dossier(_ arguments: JSONValue) async throws -> String {
        guard let name = arguments["entity"]?.stringValue else { throw RPCError.invalidParams("entity is required") }
        guard let entity = try await resolveEntityForCaller(name) else {
            return "No entity known as '\(name)'."
        }
        let activePolicy = try await policy(for: name)
        guard activePolicy.admits(entity.domain) else {
            return "'\(name)' is in the \(entity.domain.rawValue) domain, which this server does not expose."
        }
        guard let snapshot = try await store.dossier(for: entity.id) else {
            return "No dossier available for '\(entity.canonicalName)'."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var lines = [
            "# \(snapshot.entity.canonicalName) (\(snapshot.entity.kind.rawValue) · \(snapshot.entity.domain.rawValue))",
            "first seen: \(formatter.string(from: snapshot.entity.firstSeenAt))",
        ]
        let exposedAliases = sensitiveDomainsUnlockable ? snapshot.aliases : try await store.aliasesForExternalCaller(for: entity.id)
        if !exposedAliases.isEmpty {
            lines.append("aliases: \(exposedAliases.prefix(10).joined(separator: ", "))")
        }

        var admittedClaims: [DossierClaim] = []
        for row in snapshot.claims {
            guard try await ClaimAdmission.admits(row.claim, policy: activePolicy, store: store) else { continue }
            admittedClaims.append(row)
        }
        lines.append("")
        lines.append("## Believed now (\(admittedClaims.count))")
        if admittedClaims.isEmpty {
            lines.append("  none")
        } else {
            for row in admittedClaims.prefix(40) {
                let mult = row.occurrences > 1 ? " ×\(row.occurrences)" : ""
                lines.append("  [\(row.claim.derivation.rawValue)] \(row.claim.predicate) → \(row.value)\(mult)  (confidence \(String(format: "%.2f", row.claim.confidence)), \(row.claim.authority.label))")
            }
        }

        var admittedContradictions: [Contradiction] = []
        for item in snapshot.contradictions {
            guard let claimA = try await store.claim(item.claimA),
                  let claimB = try await store.claim(item.claimB),
                  try await ClaimAdmission.admits(claimA, policy: activePolicy, store: store),
                  try await ClaimAdmission.admits(claimB, policy: activePolicy, store: store)
            else { continue }
            admittedContradictions.append(item)
        }
        if !admittedContradictions.isEmpty {
            lines.append("")
            lines.append("## Contradictions (\(admittedContradictions.count))")
            for item in admittedContradictions.prefix(20) {
                lines.append("  \(item.kind.rawValue) → \(item.resolution.rawValue): \(item.reason)")
            }
        }

        let admittedEvents = snapshot.events.filter { activePolicy.admits($0.domain) }
        if !admittedEvents.isEmpty {
            lines.append("")
            lines.append("## Timeline (\(admittedEvents.count))")
            for event in admittedEvents.prefix(25) {
                lines.append("  \(formatter.string(from: event.occurredAt))  \(event.verb)  \(event.detail.replacingOccurrences(of: "\n", with: " ").prefix(180))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func timeline(_ arguments: JSONValue) async throws -> String {
        let days = min(max(1, arguments["days"]?.intValue ?? 30), 36_500)
        let entityFilter = arguments["entity"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activePolicy = try await policy(for: entityFilter ?? "")

        var targetEntityID: EntityID?
        if let entityFilter, !entityFilter.isEmpty {
            guard let resolved = try await resolveEntityForCaller(entityFilter) else {
                return "No entity known as '\(entityFilter)'."
            }
            guard activePolicy.admits(resolved.domain) else {
                return "'\(entityFilter)' is in the \(resolved.domain.rawValue) domain, which this server does not expose."
            }
            targetEntityID = resolved.id
        }

        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        // The subject filter runs in SQL. It used to run on the newest 200 rows of everything,
        // so an entity whose events were older than that read as having none.
        let rawEvents = try await store.events(
            from: since,
            to: Date().addingTimeInterval(365 * 86_400),
            domains: activePolicy.admitted,
            subject: targetEntityID,
            limit: 200
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        for event in rawEvents {
            guard lines.count < 60 else { break }
            guard activePolicy.admits(event.domain) else { continue }
            guard let subject = try await store.entity(event.subject),
                  activePolicy.admits(subject.domain)
            else { continue }
            let cleanDetail = event.detail.replacingOccurrences(of: "\n", with: " ").prefix(180)
            lines.append("\(formatter.string(from: event.occurredAt))  [\(event.verb)]  \(subject.canonicalName): \(cleanDetail)")
        }

        return lines.isEmpty
            ? "No timeline events in the last \(days) days."
            : lines.joined(separator: "\n")
    }

    // MARK: - Policy

    private func resolveEntityForCaller(_ name: String) async throws -> CoreEntity? {
        if sensitiveDomainsUnlockable { return try await store.resolve(surface: name).first?.0 }
        return try await store.resolveForExternalCaller(surface: name).first?.0
    }

    private func policy(for query: String) async throws -> AdmissionPolicy {
        let (domain, requested) = AdmissionPolicy.classifyDomain(
            query,
            knownEntitySurfaces: sensitiveDomainsUnlockable ? try await store.aliasSurfaces() : try await store.aliasSurfacesForExternalCaller()
        )
        // An external caller cannot unlock a sensitive domain by wording, and cannot land
        // in one either: a query that classifies as medical is re-based to project.
        if !sensitiveDomainsUnlockable {
            return AdmissionPolicy.forQuestion(query, externalCaller: true)
        }
        return AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested, allowRestricted: true)
    }

    /// A belief's reason, unless it quotes something this caller may not read.
    ///
    /// A version's reason is stored text that names the value it replaced, and a slot's subject
    /// ignores domain, so a project-domain plan that follows a restricted one printed the restricted
    /// sentence. Gating the version on its own claim can't catch that, because its own claim is
    /// fine. Nothing here depends on the replaced row still being readable: if it can't be found
    /// and admitted, the reason is withheld.
    private func admittedReason(_ belief: Belief, policy: AdmissionPolicy) async throws -> String {
        guard let replaced = belief.supersedes else { return belief.reason }
        let history = try await store.beliefHistory(key: belief.claimKey)
        guard let previous = history.first(where: { $0.id == replaced }),
              let claim = try await store.claim(previous.claimID),
              try await ClaimAdmission.admits(claim, policy: policy, store: store)
        else { return "replaced a value this server does not expose" }
        return belief.reason
    }



    // MARK: - Transport

    private func write(_ response: RPCResponse) {
        guard let data = try? response.serialized(),
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
