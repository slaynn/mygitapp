import Foundation

/// Tells what a folder the user is adding contains. Nothing is ever searched outside that folder.
public enum RepoLocator {
    public enum Location: Equatable, Sendable {
        /// The folder is a Repo.
        case repo(URL)
        /// The folder is a Worktree; the URL is its Repo.
        case worktree(of: URL)
        /// The folder holds Repos (possibly none deeper than `maxDepth`).
        case parent(of: [URL])
        case notGit
    }

    private static let maxDepth = 3
    private static let skippedDirectories: Set<String> = ["node_modules", "vendor"]

    public static func locate(_ folder: URL) -> Location {
        let folder = canonical(folder)
        switch gitEntry(in: folder) {
        case .directory:
            return .repo(folder)
        case .file:
            return mainRepo(ofWorktree: folder).map { .worktree(of: $0) } ?? .notGit
        case nil:
            let repos = findRepos(in: folder, depth: 0)
            return repos.isEmpty ? .notGit : .parent(of: repos)
        }
    }

    /// One spelling per folder (no symlink, no trailing slash), so the same Repo is never listed twice.
    public static func canonical(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false), directoryHint: .notDirectory)
    }

    private enum GitEntry { case directory, file }

    private static func gitEntry(in folder: URL) -> GitEntry? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? .directory : .file
    }

    /// A Worktree's common git directory is its Repo's `.git`; a submodule's is not, and is refused.
    private static func mainRepo(ofWorktree folder: URL) -> URL? {
        guard let path = try? Git(path: folder).run("rev-parse", "--path-format=absolute", "--git-common-dir") else { return nil }
        let commonDir = canonical(URL(fileURLWithPath: path))
        guard commonDir.lastPathComponent == ".git" else { return nil }
        let repo = canonical(commonDir.deletingLastPathComponent())
        return gitEntry(in: repo) == .directory ? repo : nil
    }

    private static func findRepos(in directory: URL, depth: Int) -> [URL] {
        guard depth < maxDepth,
              let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return children
            .filter { !$0.lastPathComponent.hasPrefix(".") && !skippedDirectories.contains($0.lastPathComponent) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .flatMap { child -> [URL] in
                switch gitEntry(in: child) {
                case .directory: [canonical(child)]
                // Worktrees are listed under their Repo, never as Repos.
                case .file: []
                case nil: findRepos(in: child, depth: depth + 1)
                }
            }
    }
}
