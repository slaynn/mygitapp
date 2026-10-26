import Foundation

public struct PruneLog: Sendable {
    public static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MyGitApp/prune-log.json")

    public struct Entry: Codable, Sendable {
        public let repoPath: String
        public let branch: String
        public let commit: String
        public let date: Date
        public let deletedOnOrigin: Bool

        public init(repoPath: String, branch: String, commit: String, date: Date = Date(), deletedOnOrigin: Bool) {
            self.repoPath = repoPath
            self.branch = branch
            self.commit = commit
            // Whole seconds, as stored: an entry still in memory must equal the one read back from the file.
            self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
            self.deletedOnOrigin = deletedOnOrigin
        }
    }

    private let fileURL: URL

    public init(fileURL: URL = PruneLog.defaultFileURL) {
        self.fileURL = fileURL
    }

    private static let retention: TimeInterval = 30 * 86_400
    /// A Prune and a restore from the Journal may rewrite the file at the same time: no entry may be lost.
    private static let lock = NSRecursiveLock()

    public func append(_ entry: Entry) throws {
        try Self.lock.withLock { try write(try entries() + [entry]) }
    }

    /// Entries from the last 30 days; older ones are dropped from the file.
    public func entries() throws -> [Entry] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let all = try decoder.decode([Entry].self, from: Data(contentsOf: fileURL))
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let recent = all.filter { $0.date >= cutoff }
        if recent.count != all.count { try write(recent) }
        return recent
    }

    /// The commit still exists and no local branch has that name.
    public func isRestorable(_ entry: Entry) -> Bool {
        let git = Git(path: URL(fileURLWithPath: entry.repoPath))
        return (try? git.run("cat-file", "-e", "\(entry.commit)^{commit}")) != nil
            && (try? git.run("show-ref", "--verify", "--quiet", "refs/heads/\(entry.branch)")) == nil
    }

    /// Recreates the branch at the logged commit (and on origin if it was deleted there), then drops the entry.
    /// Origin goes first: a failed push leaves nothing half restored. The empty lease only lets the push create
    /// the branch, so a same-named branch pushed since (even one the commit would fast-forward) is never moved.
    public func restore(_ entry: Entry) throws {
        guard isRestorable(entry) else {
            throw RestoreRefusal(description: "\(entry.branch) cannot be restored: its commit is gone or the name is taken")
        }
        let git = Git(path: URL(fileURLWithPath: entry.repoPath))
        if entry.deletedOnOrigin {
            try git.run("push", "--force-with-lease=refs/heads/\(entry.branch):", "origin", "\(entry.commit):refs/heads/\(entry.branch)")
        }
        try git.run("branch", "--", entry.branch, entry.commit)
        // Back to Tracked when origin has it, instead of looking Local Only (never pushed) and Risky.
        if (try? git.run("rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(entry.branch)")) != nil {
            _ = try? git.run("branch", "--set-upstream-to=origin/\(entry.branch)", entry.branch)
        }
        try remove(entry)
    }

    func remove(_ entry: Entry) throws {
        try Self.lock.withLock {
            try write(entries().filter {
                !($0.repoPath == entry.repoPath && $0.branch == entry.branch && $0.commit == entry.commit && $0.date == entry.date)
            })
        }
    }

    private struct RestoreRefusal: Error, CustomStringConvertible {
        let description: String
    }

    private func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
