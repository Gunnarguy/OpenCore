import CoreModel
import CoreStore

/// One admission decision shared by answers, MCP and the owner companion channel.
public enum ClaimAdmission {
    public static func admits(_ claim: CoreClaim, policy: AdmissionPolicy, store: Store) async throws -> Bool {
        // Store owns the shared SQL predicate, also used ahead of pagination in owner reads.
        // The former MCP check admitted unsupported claims and dangling evidence.
        guard policy.admits(claim.domain) else { return false }
        return try await store.ownerAdmitsClaim(claim.id, domains: policy.admitted)
    }
}
