import Foundation
import Observation

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyGitApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// A repo shown in the sidebar. `localPath` is set when it was added from a local clone.
struct PinnedRepo: Codable, Hashable, Identifiable {
    var id = UUID()
    var nameWithOwner: String
    var localPath: String?

    var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
    var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }
    var htmlURL: URL { URL(string: "https://github.com/\(nameWithOwner)")! }
}

/// The curated sidebar list, persisted to `repos.json`.
@MainActor @Observable
final class RepoStore {
    private(set) var pinned: [PinnedRepo] = []
    private let fileURL: URL

    init(fileURL: URL = AppPaths.support.appendingPathComponent("repos.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([PinnedRepo].self, from: data) {
            pinned = list
        }
    }

    var pinnedNames: Set<String> { Set(pinned.map { $0.nameWithOwner.lowercased() }) }

    func contains(_ nameWithOwner: String) -> Bool {
        pinned.contains { $0.nameWithOwner.caseInsensitiveCompare(nameWithOwner) == .orderedSame }
    }

    func repo(named nameWithOwner: String) -> PinnedRepo? {
        pinned.first { $0.nameWithOwner.caseInsensitiveCompare(nameWithOwner) == .orderedSame }
    }

    /// Adds a repo, or attaches `localPath` to an existing entry.
    func add(_ nameWithOwner: String, localPath: String? = nil) {
        if let index = pinned.firstIndex(where: { $0.nameWithOwner.caseInsensitiveCompare(nameWithOwner) == .orderedSame }) {
            if let localPath { pinned[index].localPath = localPath }
        } else {
            pinned.append(PinnedRepo(nameWithOwner: nameWithOwner, localPath: localPath))
        }
        save()
    }

    func remove(_ nameWithOwner: String) {
        pinned.removeAll { $0.nameWithOwner.caseInsensitiveCompare(nameWithOwner) == .orderedSame }
        save()
    }

    func toggle(_ nameWithOwner: String) {
        contains(nameWithOwner) ? remove(nameWithOwner) : add(nameWithOwner)
    }

    func move(from source: IndexSet, to destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(pinned) { try? data.write(to: fileURL, options: .atomic) }
    }
}
