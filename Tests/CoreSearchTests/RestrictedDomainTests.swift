import CoreModel
import Testing
@testable import CoreSearch

// Original bug: mixed provider memory and unknown summaries were tagged project, making
// personal and medical content accessible to ordinary project questions over MCP.
@Test("restricted memory never opens from ordinary or explicitly named query domains")
func restrictedMemoryNeedsExplicitUnsafeAdmission() {
    for domain in Domain.allCases {
        #expect(!AdmissionPolicy(queryDomain: domain, explicitlyRequested: [.restricted]).admits(.restricted))
    }
    #expect(AdmissionPolicy(queryDomain: .project, allowRestricted: true).admits(.restricted))
}


// Personal markers were recognized but discarded; adding them must never open a model caller.
@Test("owner personal questions and explicit scope remain bounded separately from external callers")
func ownerPersonalScopeDoesNotWidenExternalAdmission() {
    for query in ["my journal", "my calendar", "my reminders", "my notes"] {
        #expect(AdmissionPolicy.forQuestion(query).admits(.personal))
        #expect(!AdmissionPolicy.forQuestion(query, externalCaller: true).admits(.personal))
    }
    let selected = AdmissionPolicy.forQuestion("doctor", ownerDomain: .personal)
    #expect(selected.admitted == [.personal, .publicRecord])
    #expect(!selected.admits(.medical))
    let denied = AdmissionPolicy.forQuestion("my calendar", ownerDomain: .personal, maximumDomains: [.project, .publicRecord])
    #expect(!denied.admits(.personal))
    for selection in Domain.allCases {
        let external = AdmissionPolicy.forQuestion("my medical calendar", externalCaller: true, ownerDomain: selection)
        #expect(external.admitted == [.project, .publicRecord])
    }
    #expect(!AdmissionPolicy.forQuestion("restricted", ownerDomain: .restricted).admits(.restricted))
    #expect(!AdmissionPolicy.forQuestion("Which project handles calendar reminders?").admits(.personal))
}


// Read permission and cloud consent were conflated; project selection could mask a private question.
@Test("private raw questions and owner scopes never authorize optional cloud fallback")
func ownerReadPermissionIsNotCloudConsent() {
    let project = AdmissionPolicy(queryDomain: .project)
    #expect(project.permitsCloudFallback(for: "What is Quillberry built with?"))
    for question in ["my diagnosis", "my journal", "my calendar", "my salary", "my colleague", "my partner"] {
        #expect(!project.permitsCloudFallback(for: question))
    }
    for domain in Domain.allCases {
        #expect(!project.permitsCloudFallback(for: "Quillberry", explicitOwnerDomain: domain))
    }
    for domain in [Domain.personal, .work, .medical, .financial, .relationship] {
        #expect(!AdmissionPolicy(queryDomain: domain).permitsCloudFallback(for: "Quillberry"))
    }
    #expect(!AdmissionPolicy(queryDomain: .project, maximumDomains: []).permitsCloudFallback(for: "Quillberry"))
}
