import Foundation

struct LocalRepoInfo: Hashable, Identifiable {
    var path: String
    var nameWithOwner: String?
    var branch: String?
    var id: String { path }
    var folderName: String { (path as NSString).lastPathComponent }
}

/// Reads git metadata straight from `.git` (no process spawn), so scanning a folder of
/// dozens of clones stays instant.
enum LocalRepoResolver {
    /// `git@github.com:o/r.git`, `https://github.com/o/r`, `ssh://git@github.com/o/r.git`,
    /// and SSH host aliases such as `git@github.com-work:o/r.git` → `o/r`.
    static func parseGitHubRemote(_ remote: String) -> String? {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: Substring
        var path: Substring
        if let schemeEnd = url.range(of: "://") {
            let rest = url[schemeEnd.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = rest[..<slash]
            path = rest[rest.index(after: slash)...]
        } else if let colon = url.firstIndex(of: ":") {
            host = url[..<colon]
            path = url[url.index(after: colon)...]
        } else {
            return nil
        }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let port = host.firstIndex(of: ":") { host = host[..<port] }
        guard host.lowercased().hasPrefix("github.com") else { return nil }

        var components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        components = Array(components.prefix(2))
        if components[1].hasSuffix(".git") { components[1].removeLast(4) }
        guard !components[0].isEmpty, !components[1].isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// `[remote "origin"] url = …` entries from a git config file.
    static func parseRemotes(config: String) -> [(name: String, url: String)] {
        var remotes: [(String, String)] = []
        var current: String?
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if line.hasPrefix("[remote \""), let end = line.lastIndex(of: "\"") {
                    let start = line.index(line.startIndex, offsetBy: 9)
                    current = start < end ? String(line[start..<end]) : nil
                } else {
                    current = nil
                }
            } else if let name = current, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" {
                    remotes.append((name, parts[1].trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return remotes
    }

    /// Resolves a working tree (regular clone or worktree) to its GitHub repo and branch.
    static func resolve(path: String) -> LocalRepoInfo? {
        let fm = FileManager.default
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }

        var gitDir = dotGit
        var commonDir = dotGit
        if !isDir.boolValue {
            // Worktree or submodule: `.git` is a file pointing at the real git dir.
            guard let content = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = content.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = target.hasPrefix("/") ? target : (path as NSString).appendingPathComponent(target)
            commonDir = gitDir
            if let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
                let rel = common.trimmingCharacters(in: .whitespacesAndNewlines)
                commonDir = rel.hasPrefix("/") ? rel : ((gitDir as NSString).appendingPathComponent(rel) as NSString).standardizingPath
            }
        }

        let config = (try? String(contentsOfFile: (commonDir as NSString).appendingPathComponent("config"), encoding: .utf8)) ?? ""
        let remotes = parseRemotes(config: config)
        let preferred = remotes.first { $0.name == "origin" } ?? remotes.first { $0.name == "upstream" } ?? remotes.first
        let ordered = (preferred.map { [$0] } ?? []) + remotes
        let nameWithOwner = ordered.lazy.compactMap { parseGitHubRemote($0.url) }.first

        var branch: String?
        if let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8) {
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ref: refs/heads/") {
                branch = String(trimmed.dropFirst("ref: refs/heads/".count))
            } else if trimmed.count >= 7 {
                branch = String(trimmed.prefix(7))
            }
        }
        return LocalRepoInfo(path: path, nameWithOwner: nameWithOwner, branch: branch)
    }

    private static let skipped: Set<String> = ["node_modules", "vendor", "Pods", "build", "dist", "DerivedData", "Library"]

    /// Git clones under `parent`, up to `maxDepth` levels deep, without descending into clones.
    static func scan(parent: URL, maxDepth: Int = 3) -> [LocalRepoInfo] {
        var results: [LocalRepoInfo] = []
        func visit(_ url: URL, depth: Int) {
            if let info = resolve(path: url.path) {
                results.append(info)
                return
            }
            guard depth < maxDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            else { return }
            for child in children where !skipped.contains(child.lastPathComponent) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { visit(child, depth: depth + 1) }
            }
        }
        visit(parent, depth: 0)
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
