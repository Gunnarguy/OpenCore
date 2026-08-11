import CoreModel
import Foundation

/// A saved chat thread.
public struct StoredConversation: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var updatedAt: Date
    public var turnCount: Int

    public init(id: String, title: String, startedAt: Date, updatedAt: Date, turnCount: Int) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.turnCount = turnCount
    }
}

/// What a person said about an answer after reading it.
///
/// Two values and no middle. A three-point scale invites the safe middle and produces a corpus
/// of shrugs; the question worth answering is whether the answer was usable, and that has two
/// sides. `nil` is not the middle, it is *unjudged*, which is a different fact and stays
/// distinguishable.
public enum TurnJudgement: String, Sendable, Hashable, Codable, CaseIterable {
    case good
    case bad
}

/// One saved exchange, with its payloads left as JSON.
///
/// `sources` and `verdicts` stay opaque strings here on purpose. They are `CoreReason` types,
/// and `CoreStore` sits below `CoreReason`; decoding them here would invert the layering to
/// save a mapping function. The receipt is different and is a real foreign key, because it has
/// a table of its own and `opencore trace` has to reach it.
public struct StoredTurn: Sendable, Hashable, Identifiable {
    public var id: String
    public var conversationID: String
    public var ordinal: Int
    public var role: String
    public var text: String
    public var sourcesJSON: String
    public var verdictsJSON: String
    public var receiptID: ReceiptID?
    public var model: String?
    public var error: String?
    public var createdAt: Date
    /// `nil` means nobody has said. Never inferred from silence.
    public var judgement: TurnJudgement?
    public var judgedAt: Date?

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        ordinal: Int,
        role: String,
        text: String,
        sourcesJSON: String = "[]",
        verdictsJSON: String = "[]",
        receiptID: ReceiptID? = nil,
        model: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        judgement: TurnJudgement? = nil,
        judgedAt: Date? = nil
    ) {
        self.judgement = judgement
        self.judgedAt = judgedAt
        self.id = id
        self.conversationID = conversationID
        self.ordinal = ordinal
        self.role = role
        self.text = text
        self.sourcesJSON = sourcesJSON
        self.verdictsJSON = verdictsJSON
        self.receiptID = receiptID
        self.model = model
        self.error = error
        self.createdAt = createdAt
    }
}

extension Store {
    /// Start a thread, or leave an existing one untouched.
    ///
    /// Idempotent so a caller that does not track whether it has saved yet can call this before
    /// every append without branching, which is exactly what the chat path wants: the first
    /// turn creates the thread and the rest find it already there.
    public func openConversation(id: String, title: String, at date: Date = Date()) async throws {
        try await database.execute(
            """
            INSERT INTO conversation (id, title, started_at, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [.text(id), .text(title), .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970)]
        )
    }

    /// Append a turn and mark its thread as recently used.
    ///
    /// One `write` block so a turn cannot land without its conversation's `updated_at` moving.
    /// Split across two calls, a crash between them leaves a thread whose last activity is a
    /// lie, and the resume list is sorted by exactly that column.
    public func append(_ turn: StoredTurn) async throws {
        try await database.write { connection in
            try connection.execute(
                """
                INSERT INTO conversation_turn
                    (id, conversation_id, ordinal, role, text, sources, verdicts, receipt_id, model, error, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    text = excluded.text, sources = excluded.sources, verdicts = excluded.verdicts,
                    receipt_id = excluded.receipt_id, model = excluded.model, error = excluded.error
                """,
                [
                    .text(turn.id), .text(turn.conversationID), .integer(Int64(turn.ordinal)),
                    .text(turn.role), .text(turn.text), .text(turn.sourcesJSON), .text(turn.verdictsJSON),
                    SQLValue(text: turn.receiptID?.value), SQLValue(text: turn.model),
                    SQLValue(text: turn.error), .real(turn.createdAt.timeIntervalSince1970),
                ]
            )
            try connection.execute(
                "UPDATE conversation SET updated_at = ? WHERE id = ?",
                [.real(turn.createdAt.timeIntervalSince1970), .text(turn.conversationID)]
            )
        }
    }

    /// Threads, most recently used first.
    public func conversations(limit: Int = 100) async throws -> [StoredConversation] {
        try await database.query(
            """
            SELECT c.id AS id, c.title AS title, c.started_at AS started_at, c.updated_at AS updated_at,
                   COUNT(t.id) AS turns
            FROM conversation c LEFT JOIN conversation_turn t ON t.conversation_id = c.id
            GROUP BY c.id ORDER BY c.updated_at DESC LIMIT ?
            """,
            [.integer(Int64(limit))]
        ).map {
            StoredConversation(
                id: $0.requireString("id"),
                title: $0.requireString("title"),
                startedAt: $0.requireDate("started_at"),
                updatedAt: $0.requireDate("updated_at"),
                turnCount: $0.requireInt("turns")
            )
        }
    }

    public func conversation(id: String) async throws -> StoredConversation? {
        try await conversations(limit: 1000).first { $0.id == id }
    }

    /// Every turn of one thread, in the order it happened.
    public func turns(conversationID: String) async throws -> [StoredTurn] {
        try await database.query(
            "SELECT * FROM conversation_turn WHERE conversation_id = ? ORDER BY ordinal ASC",
            [.text(conversationID)]
        ).map(StoredTurn.init(row:))
    }

    /// Record, change, or withdraw a verdict on one answer.
    ///
    /// Written separately from `append` rather than folded into it, because a judgement arrives
    /// long after the turn does and re-appending the whole turn to carry one column would risk
    /// overwriting text with a stale copy held in a view.
    ///
    /// Passing `nil` withdraws the verdict and clears the timestamp with it. Leaving a
    /// `judged_at` behind on an unjudged row would make the corpus report a labelling that no
    /// longer exists.
    public func judge(turn id: String, as judgement: TurnJudgement?, at date: Date = Date()) async throws {
        try await database.execute(
            "UPDATE conversation_turn SET judgement = ?, judged_at = ? WHERE id = ?",
            [SQLValue(text: judgement?.rawValue), judgement == nil ? .null : .real(date.timeIntervalSince1970), .text(id)]
        )
    }

    /// Every judged answer, newest first. This is the eval corpus, grown by using the product.
    ///
    /// Only `core` turns can carry a verdict, since judging your own question is meaningless,
    /// but the filter is on `judgement IS NOT NULL` rather than on role: a judgement that
    /// somehow landed on a question is a bug worth seeing rather than hiding.
    public func judgedTurns(limit: Int = 500) async throws -> [StoredTurn] {
        try await database.query(
            "SELECT * FROM conversation_turn WHERE judgement IS NOT NULL ORDER BY judged_at DESC LIMIT ?",
            [.integer(Int64(limit))]
        ).map(StoredTurn.init(row:))
    }

    /// How many answers have been judged each way, and how many never were.
    public func judgementCounts() async throws -> (good: Int, bad: Int, unjudged: Int) {
        let rows = try await database.query(
            """
            SELECT judgement AS j, COUNT(*) AS n FROM conversation_turn
            WHERE role = 'core' GROUP BY judgement
            """
        )
        var good = 0, bad = 0, unjudged = 0
        for row in rows {
            let n = row.requireInt("n")
            switch row.string("j").flatMap(TurnJudgement.init(rawValue:)) {
            case .good: good = n
            case .bad: bad = n
            // Counted, not folded into either side. "Nobody said" is its own fact, and an
            // accuracy figure computed over judged answers alone must be able to report the
            // denominator it ignored.
            case nil: unjudged = n
            }
        }
        return (good, bad, unjudged)
    }

    /// Remove a thread and its turns.
    ///
    /// This is a genuine delete, and it is allowed to be, because a conversation is not
    /// evidence. The rule it might look like it breaks, "never delete to record a change of
    /// mind", is about retracting a *claim*: a retracted claim stays as a row because
    /// something downstream may have relied on it. Nothing derives from a chat turn, and a
    /// user asking to forget a conversation means forget it.
    public func deleteConversation(id: String) async throws {
        // Receipts deliberately survive. They are referenced by `receipt_evidence` and reached
        // by `opencore trace`, and the turn's foreign key is ON DELETE SET NULL rather than
        // CASCADE for that reason.
        try await database.execute("DELETE FROM conversation WHERE id = ?", [.text(id)])
    }

    public func renameConversation(id: String, title: String) async throws {
        try await database.execute(
            "UPDATE conversation SET title = ? WHERE id = ?", [.text(title), .text(id)]
        )
    }
}

extension StoredTurn {
    /// One decoder, used by every reader. Two copies of a column list is how one of them
    /// quietly stops reading a column added later, and the symptom is a field that is always
    /// nil down one code path and correct down another.
    init(row: Row) {
        self.init(
            id: row.requireString("id"),
            conversationID: row.requireString("conversation_id"),
            ordinal: row.requireInt("ordinal"),
            role: row.requireString("role"),
            text: row.requireString("text"),
            sourcesJSON: row.string("sources") ?? "[]",
            verdictsJSON: row.string("verdicts") ?? "[]",
            receiptID: row.string("receipt_id").map { ReceiptID($0) },
            model: row.string("model"),
            error: row.string("error"),
            createdAt: row.requireDate("created_at"),
            judgement: row.string("judgement").flatMap(TurnJudgement.init(rawValue:)),
            judgedAt: row.date("judged_at")
        )
    }
}
