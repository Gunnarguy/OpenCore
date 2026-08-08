import CoreModel
import Foundation

/// Decides what a query is allowed to see, before relevance is even considered.
///
/// This runs *ahead* of scoring, not after. A high-similarity match from a blocked domain
/// is never ranked and then filtered, because a filter applied after ranking still leaked
/// the fact that something relevant exists there, and because "top 20 then filter" quietly
/// starves the allowed domains of slots.
public struct AdmissionPolicy: Sendable {
    public let queryDomain: Domain
    public let admitted: Set<Domain>
    public let blocked: Set<Domain>

    /// Sensitive domains open only when the query names them. Inference is not consent:
    /// a question that merely *sounds* medical does not unlock medical records.
    public init(queryDomain: Domain, explicitlyRequested: Set<Domain> = []) {
        self.queryDomain = queryDomain
        var allowed = queryDomain.readableDomains
        allowed.formUnion(explicitlyRequested.filter { $0.isSensitive })
        self.admitted = allowed
        self.blocked = Set(Domain.allCases).subtracting(allowed)
    }

    public func admits(_ domain: Domain) -> Bool { admitted.contains(domain) }

    static let markers: [(Domain, [String])] = [
        (.medical, ["diagnosis", "symptom", "symptoms", "medication", "prescription", "doctor", "clinic", "patient", "lab result", "lab results"]),
        (.financial, ["salary", "invoice", "tax", "taxes", "bank", "revenue", "expense", "expenses", "payment", "budget"]),
        (.relationship, ["girlfriend", "boyfriend", "partner", "spouse", "family", "friend", "friends"]),
        (.work, ["meeting", "manager", "colleague", "colleagues", "shift", "employer", "coworker"]),
        (.personal, ["diary", "journal"]),
    ]

    /// Classify a query into a domain from its wording.
    ///
    /// Two rules earn their keep here, both learned the hard way:
    ///
    /// 1. **Whole words, never substrings.** Matching `clinic` inside a sentence is fine;
    ///    matching it inside `OpenClinic` is not. Substring matching turned a question
    ///    about a project into a medical query and blocked the entire corpus.
    /// 2. **A known entity outranks a keyword.** If a token resolves to something already
    ///    in the graph, it is a name, and names are removed before keyword scanning. A
    ///    project called OpenClinic, a repo called Budget, a branch called `patient-fix`
    ///    should not each detonate the firewall.
    ///
    /// Unknown wording lands in `.project`, the least sensitive working domain, rather
    /// than in whatever seemed most likely.
    public static func classifyDomain(
        _ query: String,
        knownEntitySurfaces: Set<String> = []
    ) -> (Domain, Set<Domain>) {
        var lowered = query.lowercased()

        // Mask known names first, longest first so `open clinic` is removed before `clinic`.
        for surface in knownEntitySurfaces.sorted(by: { $0.count > $1.count }) where surface.count > 2 {
            lowered = lowered.replacingOccurrences(of: surface.lowercased(), with: " ")
        }

        var requested: Set<Domain> = []
        for (domain, keywords) in markers where keywords.contains(where: { containsWord($0, in: lowered) }) {
            requested.insert(domain)
        }

        // A sensitive domain named in the query is an explicit request and becomes the
        // query's own domain. Otherwise fall back to project work.
        if let sensitive = requested.sorted(by: { $0.rawValue < $1.rawValue }).first(where: { $0.isSensitive }) {
            return (sensitive, requested)
        }
        if requested.contains(.work) { return (.work, requested) }
        return (.project, requested)
    }

    /// Whole-word (or whole-phrase) containment. `clinic` matches "the clinic called" but
    /// not "OpenClinic"; `tax` matches "my tax bill" but not "syntax".
    public static func containsWord(_ needle: String, in haystack: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let beforeOK = found.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: found.lowerBound)].isLetterOrDigit
            let afterOK = found.upperBound == haystack.endIndex
                || !haystack[found.upperBound].isLetterOrDigit
            if beforeOK && afterOK { return true }
            guard found.upperBound < haystack.endIndex else { return false }
            searchRange = found.upperBound..<haystack.endIndex
        }
        return false
    }
}

extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}
