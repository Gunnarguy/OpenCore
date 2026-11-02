#if os(macOS)
import Foundation

/// A reconnect may acknowledge the same prepared reply again. Audit persistence happens
/// once, even when two authenticated connections race or the first final response is lost.
actor CompanionDelivery {
    private let prepared: CompanionPreparedPage
    private var completed: CompanionPage?
    private var committing: (id: UUID, task: Task<CompanionPage, any Error>)?
    init(_ prepared: CompanionPreparedPage) { self.prepared = prepared }
    func validateDisclosure() async throws { try await prepared.validateDisclosure() }
    func validateReplay() async throws {
        guard prepared.canValidateReplay else { throw CompanionError.resumeUnavailable }
        try await prepared.validateDisclosure()
    }
    func acknowledge() async throws -> CompanionPage {
        if let completed { return completed }
        let current: (id: UUID, task: Task<CompanionPage, any Error>)
        if let committing { current = committing }
        else { current = (UUID(), Task { try await prepared.acknowledge() }); committing = current }
        do {
            let page = try await current.task.value
            completed = page; committing = nil
            return page
        } catch { if committing?.id == current.id { committing = nil }; throw error }
    }
}
#endif
