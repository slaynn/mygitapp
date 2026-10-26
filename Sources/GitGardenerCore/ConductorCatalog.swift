import Foundation

/// Conductor Workspaces read from the Conductor database (read-only).
struct ConductorCatalog {
    private struct Row: Decodable {
        let workspace_path: String?
        let branch: String?
        let state: String?
        let root_path: String?

        var isArchived: Bool { state == "archived" }
    }

    private static let query = """
        select w.workspace_path, w.branch, w.state, r.root_path \
        from workspaces w join repos r on r.id = w.repository_id
        """

    /// nil when the database exists but could not be read (locked, schema change...).
    private let rows: [Row]?

    init(databaseURL: URL?) {
        guard let databaseURL else {
            rows = []
            return
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            // Conductor installed but its database moved: its Workspaces cannot be told apart, so fail closed.
            rows = FileManager.default.fileExists(atPath: "/Applications/Conductor.app") ? nil : []
            return
        }
        guard let output = try? Git.execute("/usr/bin/sqlite3", ["-readonly", "-json", databaseURL.path, Self.query]) else {
            rows = nil
            return
        }
        // sqlite3 prints nothing at all for an empty result.
        rows = output.isEmpty ? [] : try? JSONDecoder().decode([Row].self, from: Data(output.utf8))
    }

    func state(repoPath: URL, branch: String, worktreePath: URL?) -> BranchAnalyzer.ConductorState? {
        guard let rows else {
            // Fail closed: without the database any Worktree might be an active Conductor Workspace.
            return worktreePath == nil ? nil : .active
        }
        if let worktreePath,
           rows.contains(where: { !$0.isArchived && Self.sameFolder($0.workspace_path, worktreePath) }) {
            return .active
        }
        let isArchived = rows.contains { $0.isArchived && $0.branch == branch && Self.sameFolder($0.root_path, repoPath) }
        return isArchived ? .archived : nil
    }

    private static func sameFolder(_ path: String?, _ url: URL) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
    }
}
