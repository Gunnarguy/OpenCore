import CoreModel
import CoreSearch
import Testing
@testable import CoreReason

// Old model context and anchors survived admission changes, including sensitive to project.
@Test("changing chat admission requires a fresh model context and retrieval anchors")
func conversationContextScopeCannotFollowSensitiveHistory() {
    var scope = ConversationAdmissionScope()
    let medical = AdmissionPolicy(queryDomain: .medical)
    let project = AdmissionPolicy(queryDomain: .project)
    let firstMedical = scope.adopt(medical)
    let repeatedMedical = scope.adopt(medical)
    let changedToProject = scope.adopt(project)
    #expect(firstMedical)
    #expect(!repeatedMedical)
    #expect(changedToProject)
    #expect(scope.admitted == [.project,.publicRecord])
    let repeatedProject = scope.adopt(project)
    #expect(!repeatedProject)
}
