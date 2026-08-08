import CoreModel
import CoreStore
import Foundation

/// Time travel along the transaction-time axis: what OpenCore believed at a past instant,
/// and how that differs from what it believes now.
///
/// This is the app's `opencore memory checkout`, plus the diff the CLI leaves to the reader.
extension AppModel {
    /// One belief slot resolved for display, as it stood at one instant.
    struct HeldBelief: Identifiable, Sendable {
        /// The slot (`subject|predicate`). Stable across versions, which is the only reason
        /// two checkouts can be lined up against each other at all.
        let id: String
        let subject: String
        let predicate: String
        let value: String
        let belief: Belief
    }

    /// One slot seen from two positions on the transaction-time axis at once.
    struct TimeTravelRow: Identifiable, Sendable {
        /// Ordered by how much the row deserves the reader's attention.
        enum Change: Int, Sendable, Equatable {
            /// Believed then, and OpenCore now believes nothing in this slot.
            case noLongerHeld = 0
            /// Believed then, believed now, different answer.
            case changed = 1
            /// Not believed then. OpenCore has learned it since.
            case learned = 2
            /// The same belief version still stands.
            case unchanged = 3
        }

        let id: String
        let subject: String
        let predicate: String
        let change: Change
        /// What the slot held at the chosen instant. `nil` for a slot learned since.
        let then: HeldBelief?
        /// What it holds now. `nil` once the claim behind it was retracted.
        let now: HeldBelief?
        /// When OpenCore stopped believing it, where that is recorded.
        let retractedAt: Date?
    }

    /// The beliefs OpenCore held at `instant`, resolved into display strings.
    ///
    /// Transaction time only. A belief here may well have been wrong about the world.
    func beliefs(asOf instant: Date) async -> [HeldBelief] {
        guard let store else { return [] }
        do {
            let resolved = try await slots(at: instant, in: store).values
            return resolved
                .filter { $0.validity.wasBelieved(at: instant) }
                .map(\.held)
                .sorted { ($0.subject, $0.predicate) < ($1.subject, $1.predicate) }
        } catch {
            state = .failed("\(error)")
            return []
        }
    }

    /// `beliefs(asOf:)` diffed against the live set.
    ///
    /// The diff is the point of the screen: a checkout on its own asks the reader to hold two
    /// lists in their head and spot the difference, which is exactly what they will get wrong.
    func timeTravel(asOf instant: Date) async -> [TimeTravelRow] {
        guard let store else { return [] }
        let present = Date()
        do {
            let thenSlots = try await slots(at: instant, in: store)
            let nowSlots = try await slots(at: present, in: store)

            var rows: [TimeTravelRow] = []
            for key in Set(thenSlots.keys).union(nowSlots.keys) {
                let thenSlot = thenSlots[key]
                let nowSlot = nowSlots[key]
                let then = thenSlot.flatMap { $0.validity.wasBelieved(at: instant) ? $0.held : nil }
                let now = nowSlot.flatMap { $0.validity.wasBelieved(at: present) ? $0.held : nil }

                // Retracted before the chosen instant and still retracted: never believed at
                // either position, so it is not a change and does not belong on the screen.
                guard let anchor = then ?? now else { continue }

                let change = classify(then: then, now: now)
                rows.append(TimeTravelRow(
                    id: key,
                    subject: anchor.subject,
                    predicate: anchor.predicate,
                    change: change,
                    then: then,
                    now: now,
                    retractedAt: change == .noLongerHeld ? nowSlot?.validity.retractedAt : nil
                ))
            }

            return rows.sorted {
                ($0.change.rawValue, $0.subject, $0.predicate) < ($1.change.rawValue, $1.subject, $1.predicate)
            }
        } catch {
            state = .failed("\(error)")
            return []
        }
    }

    private func classify(then: HeldBelief?, now: HeldBelief?) -> TimeTravelRow.Change {
        guard let then else { return .learned }
        guard let now else { return .noLongerHeld }
        return then.belief.id == now.belief.id ? .unchanged : .changed
    }

    /// Every slot the store answers for at one transaction-time position, keyed by slot.
    private func slots(at instant: Date, in store: Store) async throws -> [String: TimeTravelSlot] {
        var resolved: [String: TimeTravelSlot] = [:]
        for belief in try await store.beliefs(asOfKnowledge: instant) {
            guard let claim = try await store.claim(belief.claimID) else { continue }
            resolved[belief.claimKey] = TimeTravelSlot(
                held: HeldBelief(
                    id: belief.claimKey,
                    subject: try await displayName(of: claim.subject, in: store),
                    predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                    value: try await displayValue(of: claim, in: store),
                    belief: belief
                ),
                validity: claim.validity
            )
        }
        return resolved
    }

    // Duplicated from `AppModel`'s own naming helpers, which are file-private there.
    private func displayName(of entity: EntityID, in store: Store) async throws -> String {
        try await store.entity(entity)?.canonicalName ?? String(entity.value.prefix(8))
    }

    private func displayValue(of claim: CoreClaim, in store: Store) async throws -> String {
        if let objectEntity = claim.objectEntity, let resolved = try await store.entity(objectEntity) {
            return resolved.canonicalName
        }
        return claim.literal ?? "unknown"
    }
}

/// A resolved belief plus the **claim's** live validity.
///
/// The belief row copies the claim's validity at decision time, so its `retractedAt` is a
/// snapshot that never learns about a later retraction. Reading transaction time off the
/// belief row would report a slot as still held long after OpenCore let go of it.
private struct TimeTravelSlot {
    let held: AppModel.HeldBelief
    let validity: Validity
}
