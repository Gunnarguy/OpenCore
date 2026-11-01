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
