import Foundation

/// Tools GitGardener relies on and that may be missing on another Mac.
public enum Prerequisite: Sendable, Hashable {
    /// Without git nothing can be read: the Command Line Tools are not installed.
    case gitMissing
    /// Pull requests are not shown.
    case githubMissing
    /// Pull requests are not shown.
    case githubSignedOut

    public static func missing() -> [Prerequisite] {
        if (try? Git.execute("/usr/bin/git", ["--version"])) == nil { return [.gitMissing] }
        guard let github = BranchAnalyzer.resolveGitHubPath() else { return [.githubMissing] }
        return (try? Git.execute(github, ["auth", "token"])) == nil ? [.githubSignedOut] : []
    }
}
