import CoreModel
import CoreStore
import Foundation

/// Bitemporal time travel across both Knowledge Time (transaction time) and World Time (valid time).
extension AppModel {
    enum TimeTravelAxis: String, CaseIterable, Identifiable, Sendable {
        case knowledge = "Knowledge time"
        case world = "World time"
        case both = "Both axes"

        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .knowledge:
                "Transaction time: what OpenCore believed on this date (observedAt / retractedAt), compared against now."
            case .world:
                "Valid time: what was true in the world on this date (validFrom / validTo), compared against now."
            case .both:
                "Dual-axis bitemporal: what OpenCore knew on the Knowledge date about the world on the World date."
            }
        }
    }

    /// One belief slot resolved for display, as it stood at one instant.
    struct HeldBelief: Identifiable, Sendable {
        let id: String
        let subjectID: EntityID
        let subject: String
        let predicate: String
        let objectEntityID: EntityID?
        let value: String
        let belief: Belief
    }

    /// One slot seen from two bitemporal positions at once.
    struct TimeTravelRow: Identifiable, Sendable {
        enum Change: Int, Sendable, Equatable {
            case noLongerHeld = 0
            case changed = 1
            case learned = 2
            case unchanged = 3
        }

        let id: String
        let subjectID: EntityID
        let subject: String
        let predicate: String
        let change: Change
        let then: HeldBelief?
        let now: HeldBelief?
        let retractedAt: Date?

        var activeClaimID: ClaimID? {
            (now ?? then)?.belief.claimID
        }
    }

    /// The beliefs OpenCore held at `instant`, resolved into display strings.
    func beliefs(asOf instant: Date) async -> [HeldBelief] {
        guard let store else { return [] }
        do {
            let resolved = try await slots(asOfWorld: nil, asOfKnowledge: instant, in: store).values
            return resolved
                .filter { $0.validity.wasBelieved(at: instant) }
                .map(\.held)
                .sorted { ($0.subject, $0.predicate) < ($1.subject, $1.predicate) }
        } catch {
            state = .failed("\(error)")
            return []
        }
    }

    /// Diff the store's beliefs at the chosen bitemporal coordinates against the live set.
    func timeTravel(
        asOf instant: Date,
        worldInstant: Date? = nil,
        axis: TimeTravelAxis = .knowledge
    ) async throws -> [TimeTravelRow] {
        guard let store else { throw CocoaError(.fileReadNoSuchFile) }
        let present = Date()
        let queryWorld: Date? = switch axis {
        case .knowledge: nil
        case .world: instant
        case .both: worldInstant ?? instant
        }
        let queryKnowledge: Date? = switch axis {
        case .knowledge: instant
        case .world: nil
        case .both: instant
        }

        do {
            let thenSlots = try await slots(asOfWorld: queryWorld, asOfKnowledge: queryKnowledge, in: store)
            let nowSlots = try await slots(asOfWorld: nil, asOfKnowledge: present, in: store)

            var rows: [TimeTravelRow] = []
            for key in Set(thenSlots.keys).union(nowSlots.keys) {
                let thenSlot = thenSlots[key]
                let nowSlot = nowSlots[key]
                let then = thenSlot?.held
                let now = nowSlot.flatMap { $0.validity.wasBelieved(at: present) ? $0.held : nil }

                guard let anchor = then ?? now else { continue }

                let change = classify(then: then, now: now)
                rows.append(TimeTravelRow(
                    id: key,
                    subjectID: anchor.subjectID,
                    subject: anchor.subject,
                    predicate: anchor.predicate,
                    change: change,
                    then: then,
                    now: now,
                    retractedAt: change == .noLongerHeld ? (nowSlot?.validity.retractedAt ?? thenSlot?.validity.validTo) : nil
                ))
            }

            return rows.sorted {
                ($0.change.rawValue, $0.subject, $0.predicate) < ($1.change.rawValue, $1.subject, $1.predicate)
            }
        } catch {
            state = .failed("\(error)")
            throw error
        }
    }

    private func classify(then: HeldBelief?, now: HeldBelief?) -> TimeTravelRow.Change {
        guard let then else { return .learned }
        guard let now else { return .noLongerHeld }
        if then.belief.id == now.belief.id { return .unchanged }
        if then.value == now.value && then.belief.authority == now.belief.authority {
            return .unchanged
        }
        return .changed
    }

    private func slots(
        asOfWorld: Date?,
        asOfKnowledge: Date?,
        in store: Store
    ) async throws -> [String: TimeTravelSlot] {
        var resolved: [String: TimeTravelSlot] = [:]
        let beliefsList = try await store.beliefs(
            asOfKnowledge: asOfKnowledge ?? Date(),
            asOfWorld: asOfWorld
        )
        for belief in beliefsList {
            guard let claim = try await store.claim(belief.claimID) else { continue }
            resolved[belief.claimKey] = TimeTravelSlot(
                held: HeldBelief(
                    id: belief.claimKey,
                    subjectID: claim.subject,
                    subject: try await name(of: claim.subject, in: store),
                    predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                    objectEntityID: claim.objectEntity,
                    value: try await value(of: claim, in: store),
                    belief: belief
                ),
                validity: claim.validity
            )
        }
        return resolved
    }
}

private struct TimeTravelSlot {
    let held: AppModel.HeldBelief
    let validity: Validity
}
