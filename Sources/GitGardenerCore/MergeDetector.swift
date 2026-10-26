import Foundation

/// Answers "which Base Branches contain this branch".
struct MergeDetector {
    private static let defaultBaseBranches = ["main", "master", "develop"]

    private let git: Git
    /// Base Branch name to the full ref compared against (`refs/remotes/origin/<base>` when it exists).
    private let baseRefs: [(name: String, ref: String)]

    var baseBranches: [String] { baseRefs.map(\.name) }
    /// Never offered for deletion: the Base Branches plus the auto-detected ones, so an override
    /// (or a typo in it) cannot expose `main` or origin's default branch.
    let protectedBranches: Set<String>

    init(repoPath: URL, overrides: [String]?) {
        git = Git(path: repoPath)
        let git = git
        func exists(_ ref: String) -> Bool { (try? git.run("rev-parse", "--verify", "--quiet", ref)) != nil }
        let autoDetected = Self.autoDetectedBaseBranches(git)
        protectedBranches = Set(autoDetected + (overrides ?? []))
        baseRefs = (overrides ?? autoDetected).compactMap { name in
            if exists("refs/remotes/origin/\(name)") { return (name, "refs/remotes/origin/\(name)") }
            return exists("refs/heads/\(name)") ? (name, "refs/heads/\(name)") : nil
        }
    }

    /// The defaults plus origin's default branch (e.g. `trunk`), so it is never offered for deletion.
    private static func autoDetectedBaseBranches(_ git: Git) -> [String] {
        let prefix = "refs/remotes/origin/"
        guard let head = try? git.run("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"), head.hasPrefix(prefix) else {
            return defaultBaseBranches
        }
        let name = String(head.dropFirst(prefix.count))
        return defaultBaseBranches.contains(name) ? defaultBaseBranches : defaultBaseBranches + [name]
    }

    /// `branchRef` is a full ref (`refs/heads/...` or `refs/remotes/origin/...`), so no tag or option can shadow it.
    func mergedInto(_ branchRef: String) -> [String] {
        baseRefs.filter { isMerged(branchRef, into: $0.ref) }.map(\.name)
    }

    private func isMerged(_ branch: String, into base: String) -> Bool {
        if (try? git.run("merge-base", "--is-ancestor", branch, base)) != nil { return true }
        return isSquashMerged(branch, into: base)
    }

    private func isSquashMerged(_ branch: String, into base: String) -> Bool {
        // `commit-tree` only writes a dangling object (collected by `git gc`); no ref is touched.
        guard let mergeBase = try? git.run("merge-base", base, branch),
              let squash = try? git.run(
                  "-c", "user.name=GitGardener", "-c", "user.email=gitgardener@localhost", "-c", "commit.gpgSign=false",
                  "commit-tree", "\(branch)^{tree}", "-p", mergeBase, "-m", "squash"
              ),
              let cherry = try? git.run("cherry", base, squash)
        else { return false }
        let lines = cherry.split(separator: "\n")
        return lines.count == 1 && lines[0].hasPrefix("-")
    }
}
