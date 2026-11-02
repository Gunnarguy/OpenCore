#if os(macOS)
import CoreModel
import CoreStore
import Foundation

/// Resolves the requested subject and reads that dossier, never a default list selection.
/// Publication belongs to the caller; obsolete/cancelled requests have no completed outcome.
public enum EntityNavigationRead {
    public enum Target: Equatable, Sendable {
        case id(EntityID)
        case name(String)
    }

    public enum Outcome: Sendable {
        case loaded(EntityDossier)
        case notFound
        case failed(String)
        case discarded
    }

    @MainActor
    public static func run(
        target: Target,
        knownEntities: [CoreEntity],
        resolve: (String) async throws -> [CoreEntity],
        read: (EntityID) async throws -> EntityDossier?,
        isCurrent: () -> Bool
    ) async -> Outcome {
        guard !Task.isCancelled, isCurrent() else { return .discarded }
        do {
            let id: EntityID?
            switch target {
            case .id(let requested): id = requested
            case .name(let name):
                if let exact = knownEntities.first(where: {
                    $0.canonicalName.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    id = exact.id
                } else {
                    id = try await resolve(name).first?.id
                }
            }
            guard !Task.isCancelled, isCurrent() else { return .discarded }
            guard let id else { return .notFound }
            let dossier = try await read(id)
            guard !Task.isCancelled, isCurrent() else { return .discarded }
            guard let dossier else { return .notFound }
            guard dossier.entity.id == id else {
                return .failed("The returned dossier did not match the requested entity.")
            }
            return .loaded(dossier)
        } catch is CancellationError {
            return .discarded
        } catch {
            guard !Task.isCancelled, isCurrent() else { return .discarded }
            return .failed(error.localizedDescription)
        }
    }
}
#endif
