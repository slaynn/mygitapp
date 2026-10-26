import Foundation

/// Reads one Repo: its branches, Worktrees and Origin Only branches.
public enum RepoReader {
    public struct NotARepo: Error, CustomStringConvertible {
        public let path: URL
        public var description: String { "\(path.path) n'est plus un repo git" }
    }

    public static func read(at path: URL) throws -> Repo {
        // Without its own `.git`, git would silently read an enclosing repository (e.g. a dotfiles repo in `~`).
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw NotARepo(path: path) }
        let git = Git(path: path)
        let entries = try readWorktreeEntries(git)
        let main = entries.first
        let others = Array(entries.dropFirst())
        let branches = try readBranches(git, mainFolderBranch: main?.branch, worktrees: others)
        let worktrees = try others.map { entry -> Repo.Worktree in
            // A Worktree whose folder was deleted by hand has nothing left to lose and must not break the scan.
            let isMissing = !FileManager.default.fileExists(atPath: entry.path.path)
            let status = isMissing ? "" : try Git(path: entry.path).run("status", "--porcelain")
            let modified = try? entry.path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return Repo.Worktree(
                path: entry.path,
                branch: entry.branch,
                dirtyFileCount: status.isEmpty ? 0 : status.split(separator: "\n").count,
                lastActivity: modified ?? .distantPast
            )
        }
        return Repo(
            path: path,
            name: path.lastPathComponent,
            branches: branches,
            worktrees: worktrees,
            originOnlyBranches: try readOriginOnlyBranches(git, localBranches: Set(branches.map(\.name)))
        )
    }

    private struct WorktreeEntry {
        let path: URL
        let branch: String?
    }

    private static func readWorktreeEntries(_ git: Git) throws -> [WorktreeEntry] {
        try git.run("worktree", "list", "--porcelain")
            .components(separatedBy: "\n\n")
            .compactMap { block in
                var path: URL?
                var branch: String?
                for line in block.split(separator: "\n") {
                    if line.hasPrefix("worktree ") {
                        path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
                    } else if line.hasPrefix("branch refs/heads/") {
                        branch = String(line.dropFirst("branch refs/heads/".count))
                    }
                }
                return path.map { WorktreeEntry(path: $0, branch: branch) }
            }
    }

    private static func readBranches(_ git: Git, mainFolderBranch: String?, worktrees: [WorktreeEntry]) throws -> [Repo.Branch] {
        let format = "%(refname:short)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:iso8601-strict)"
        let output = try git.run("for-each-ref", "--format=\(format)", "refs/heads")
        let dates = ISO8601DateFormatter()
        return output.split(separator: "\n").map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            let name = fields[0]
            return Repo.Branch(
                name: name,
                location: Self.location(upstream: fields[1], track: fields[2]),
                lastCommitDate: dates.date(from: fields[3]) ?? .distantPast,
                worktreePath: worktrees.first { $0.branch == name }?.path,
                isCheckedOutInMainFolder: name == mainFolderBranch
            )
        }
    }

    private static func location(upstream: String, track: String) -> Repo.BranchLocation {
        if upstream.isEmpty { return .localOnly }
        if track == "[gone]" { return .gone }
        return .tracked(ahead: count("ahead", in: track), behind: count("behind", in: track))
    }

    private static func count(_ word: String, in track: String) -> Int {
        guard let range = track.range(of: "\(word) ") else { return 0 }
        return Int(track[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    private static func readOriginOnlyBranches(_ git: Git, localBranches: Set<String>) throws -> [String] {
        let output = try git.run("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin")
        let prefix = "origin/"
        var names: [String] = []
        for ref in output.split(separator: "\n") where ref.hasPrefix(prefix) && ref != "origin/HEAD" {
            let name = String(ref.dropFirst(prefix.count))
            if !localBranches.contains(name) { names.append(name) }
        }
        return names
    }
}
