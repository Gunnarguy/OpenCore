import CoreModel
import CoreSearch

/// Model transcripts and retrieval anchors have the same lifetime as their admitted set.
/// A prior question is context, never consent to open a domain in a new question.
struct ConversationAdmissionScope: Sendable {
    private(set) var admitted: Set<Domain>?
    mutating func adopt(_ policy: AdmissionPolicy) -> Bool {
        let changed = admitted != policy.admitted
        admitted = policy.admitted
        return changed
    }
}
