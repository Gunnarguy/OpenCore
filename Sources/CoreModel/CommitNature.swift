import Foundation

/// Whether a commit is the work itself or the upkeep around it.
///
/// **Why this exists.** `pushed_at` cannot tell the two apart. Four repositories "woke up" from
/// years of dormancy on the store's real history, and at least three of those pushes were README
/// edits: a repository that had not changed in sixteen months read as active because its
/// description was corrected. Bots make it worse, because a site that syncs a roadmap every
/// night looks like the busiest project in the fleet.
///
/// Decided from the commit's first line and author, which is all the floor keeps. Files changed
/// are not recorded, so a commit that hides real work behind a title like "docs" is classed as
/// upkeep. That is the safe direction: the status claim stays `.inferred` either way.
public enum CommitNature {
    /// Title prefixes that mean upkeep. **Chosen, not measured:** read off the commonest titles
    /// in the real store on 2026-10-30, not derived from anything larger.
    private static let upkeepPrefixes = [
        "docs", "doc:", "readme", "update readme", "add a readme", "add readme", "handoff",
        "state.md", "changelog", "privacy policy", "license", "typo", "merge ", "bump build",
        "bump version", "chore(roadmap", "chore(releases", "chore: update github stats",
        "chore: auto-update", "chore: bump", "auto-sync", "update fastlane report",
        "chore: update fastlane report",
    ]

    /// `[ci skip]` is how the owner's own docs-only pushes are marked.
    private static let upkeepMarkers = ["[ci skip]", "[skip ci]"]

    public static func isUpkeep(title: String, author: String? = nil) -> Bool {
        if let author = author?.lowercased(), author.hasSuffix("[bot]") || author.contains("github-actions") {
            return true
        }
        let lowered = title.lowercased()
        if upkeepMarkers.contains(where: lowered.contains) { return true }
        return upkeepPrefixes.contains(where: lowered.hasPrefix)
    }
}
