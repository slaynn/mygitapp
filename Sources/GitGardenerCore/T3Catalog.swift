import Foundation

/// T3 Code threads and the Worktrees they run in, read from T3 Code's database (read-only).
struct T3Catalog {
    private struct Row: Decodable {
        let worktree_path: String?
        let branch: String?
        let title: String?
        let archived: Int?
        let root_path: String?

        var isArchived: Bool { archived == 1 }
    }

    /// Deleted threads are gone from T3 Code: their Worktree is left to the usual verdicts.
    private static let query = """
        select json_extract(t.payload_json, '$.worktreePath') as worktree_path, \
        json_extract(t.payload_json, '$.branch') as branch, t.title, t.archived_at is not null as archived, \
        p.workspace_root as root_path \
        from orchestration_v2_projection_threads t left join projection_projects p on p.project_id = t.project_id \
        where t.deleted_at is null
        """

    /// nil when the database exists but could not be read (locked, schema change...).
    private let rows: [Row]?
    /// Where T3 Code creates its Worktrees: the ones protected when the database cannot be read.
    private let worktreesFolder: URL?

    init(directory: URL?) {
        guard let directory else {
            rows = []
            worktreesFolder = nil
            return
        }
        worktreesFolder = directory.appendingPathComponent("worktrees")
        let userData = directory.appendingPathComponent("userdata")
        let database = userData.appendingPathComponent("statev2.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else {
            // T3 Code installed but its database moved: its threads cannot be told apart, so fail closed.
            rows = FileManager.default.fileExists(atPath: userData.path) ? nil : []
            return
        }
        guard let output = try? Git.execute("/usr/bin/sqlite3", ["-readonly", "-json", database.path, Self.query]) else {
            rows = nil
            return
        }
        // sqlite3 prints nothing at all for an empty result.
        rows = output.isEmpty ? [] : try? JSONDecoder().decode([Row].self, from: Data(output.utf8))
    }

    func thread(repoPath: URL, branch: String, worktreePath: URL?) -> BranchAnalyzer.T3Thread? {
        guard let rows else {
            // Fail closed: without the database any Worktree T3 Code created might belong to an active thread.
            guard let worktreePath, let worktreesFolder, Self.isInside(worktreePath, worktreesFolder) else { return nil }
            return BranchAnalyzer.T3Thread(title: nil, isActive: true)
        }
        if let worktreePath,
           let active = rows.first(where: { !$0.isArchived && Self.sameFolder($0.worktree_path, worktreePath) }) {
            return BranchAnalyzer.T3Thread(title: active.title, isActive: true)
        }
        let archived = rows.first { row in
            guard row.isArchived else { return false }
            if let worktreePath, Self.sameFolder(row.worktree_path, worktreePath) { return true }
            return row.branch == branch && Self.sameFolder(row.root_path, repoPath)
        }
        return archived.map { BranchAnalyzer.T3Thread(title: $0.title, isActive: false) }
    }

    private static func sameFolder(_ path: String?, _ url: URL) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let folder = folder.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(folder + "/")
    }
}
