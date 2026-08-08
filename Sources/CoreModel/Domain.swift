import Foundation

/// The scope a piece of knowledge belongs to. This is the memory firewall: retrieval for a
/// query in one domain does not silently pull context from another.
///
/// Enforcement lives in `CoreSearch.AdmissionPolicy`, not here. This type only names the
/// compartments and the default read set for each.
public enum Domain: String, Sendable, Codable, CaseIterable {
    case project
    case work
    case personal
    case medical
    case financial
    case relationship
    case publicRecord = "public"

    /// Domains a query classified into `self` may read from. Anything not listed is blocked
    /// even on a perfect semantic match.
    public var readableDomains: Set<Domain> {
        switch self {
        case .project: [.project, .publicRecord]
        case .work: [.work, .project, .publicRecord]
        case .personal: [.personal, .publicRecord]
        case .medical: [.medical]
        case .financial: [.financial]
        case .relationship: [.relationship, .personal]
        case .publicRecord: [.publicRecord]
        }
    }

    /// Domains that never appear in an answer without the user naming them in the query.
    public static let sensitive: Set<Domain> = [.medical, .financial, .relationship]

    public var isSensitive: Bool { Domain.sensitive.contains(self) }
}
