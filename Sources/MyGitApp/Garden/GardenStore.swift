import Foundation
import GitGardenerCore
import Observation

/// A local clone whose branches and worktrees are analyzed: the main repo folder of a pinned repo's `localPath`
/// (a worktree resolves to its main repo, so its siblings are listed too).
struct GardenRepo: Identifiable, Hashable {
    let path: URL
    let nameWithOwner: String
    var id: URL { path }
}

struct GardenPick: Hashable {
    let repo: URL
    let branch: String
}

/// What is known about each local clone, analyzed one by one so a slow or broken repo delays nothing else.
@MainActor @Observable
final class GardenStore {
    enum Problem: Equatable {
        case missing
        case failed(String)
    }

    struct Entry {
        var repo: Repo?
        var reports: [String: BranchAnalyzer.Report] = [:]
        var baseBranches: [String] = []
        var isLoading = false
        var problem: Problem?
    }

    private struct Loaded: Sendable {
        let repo: Repo
        let reports: [String: BranchAnalyzer.Report]
        let baseBranches: [String]
    }

    /// What an analysis reports before it is done: the repo as soon as it is read, then each verdict as it is found.
    private enum Progress: Sendable {
        case repo(Repo)
        case report(String, BranchAnalyzer.Report)
    }

    private enum Outcome: Sendable {
        case loaded(Loaded)
        case missing
        case failed(String)
    }

    /// Enough to keep the Mac responsive: each analysis already runs many git processes.
    private static let maxConcurrentAnalyses = 4

    private(set) var repos: [GardenRepo] = []
    private(set) var entries: [URL: Entry] = [:]
    private(set) var prerequisites: [Prerequisite] = []
    private(set) var lastAnalysis: Date?
    private(set) var analyzedCount = 0
    private(set) var queuedCount = 0
    var picks: Set<GardenPick> = []
    /// Base Branch names per repo path; a missing entry means auto-detect.
    private(set) var baseBranchOverrides: [String: [String]]
    /// A result is kept only if no newer analysis of the same repo was started meanwhile.
    private var generations: [URL: Int] = [:]
    private var checkedPrerequisites = false
    private let overridesURL: URL

    var isAnalyzing: Bool { queuedCount > analyzedCount }

    /// Safe branches across every repo: what can be pruned without losing anything.
    var safeCount: Int {
        entries.values.reduce(0) { $0 + $1.reports.values.filter { $0.verdict == .safe }.count }
    }

    init(overridesURL: URL = AppPaths.support.appendingPathComponent("base-branches.json")) {
        self.overridesURL = overridesURL
        baseBranchOverrides = (try? Data(contentsOf: overridesURL))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    func repo(at path: URL) -> GardenRepo? { repos.first { $0.path == path } }

    /// Follows the pinned repos: resolves their local clones, forgets the ones unpinned and analyzes the new ones.
    func sync(with pinned: [PinnedRepo]) async {
        if !checkedPrerequisites {
            checkedPrerequisites = true
            prerequisites = await Task.detached { Prerequisite.missing() }.value
        }
        let locals = pinned.compactMap { repo in repo.localPath.map { (repo.nameWithOwner, $0) } }
        let resolved = await Task.detached { Self.resolve(locals) }.value
        let removed = Set(repos.map(\.path)).subtracting(resolved.map(\.path))
        for path in removed { forget(path) }
        let added = resolved.filter { entries[$0.path] == nil }.map(\.path)
        repos = resolved
        await analyze(added)
    }

    func analyzeAll() async {
        await analyze(repos.map(\.path))
    }

    func setBaseBranches(_ names: [String]?, for path: URL) {
        baseBranchOverrides[path.path] = names
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(baseBranchOverrides) { try? data.write(to: overridesURL, options: .atomic) }
        Task { await analyze([path]) }
    }

    func analyze(_ paths: [URL]) async {
        guard !paths.isEmpty else { return }
        if !isAnalyzing {
            analyzedCount = 0
            queuedCount = 0
        }
        queuedCount += paths.count
        var started: [(URL, Int)] = []
        for path in paths {
            let generation = (generations[path] ?? 0) + 1
            generations[path] = generation
            entries[path, default: Entry()].isLoading = true
            started.append((path, generation))
        }
        let overrides = baseBranchOverrides
        let analyzer = await Task.detached { BranchAnalyzer(baseBranchOverrides: overrides) }.value

        await withTaskGroup(of: (URL, Int, Outcome).self) { group in
            var pending = started[...]
            func startNext() {
                guard let (path, generation) = pending.popFirst() else { return }
                group.addTask {
                    let outcome = Self.load(path, analyzer: analyzer) { progress in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self.apply(progress, to: path, generation: generation) }
                        }
                    }
                    return (path, generation, outcome)
                }
            }
            for _ in 0..<Self.maxConcurrentAnalyses { startNext() }
            for await (path, generation, outcome) in group {
                apply(outcome, to: path, generation: generation)
                analyzedCount += 1
                startNext()
            }
        }
        if !isAnalyzing { lastAnalysis = Date() }
    }

    private func forget(_ path: URL) {
        entries[path] = nil
        generations[path] = (generations[path] ?? 0) + 1
        picks = picks.filter { $0.repo != path }
    }

    /// Rows show up with their branch data first and get their verdict one by one.
    private func apply(_ progress: Progress, to path: URL, generation: Int) {
        guard generations[path] == generation, var entry = entries[path], entry.isLoading else { return }
        switch progress {
        case let .repo(repo): entry.repo = repo
        case let .report(name, report): entry.reports[name] = report
        }
        entries[path] = entry
    }

    private func apply(_ outcome: Outcome, to path: URL, generation: Int) {
        guard generations[path] == generation, var entry = entries[path] else { return }
        entry.isLoading = false
        switch outcome {
        case let .loaded(loaded):
            entry.repo = loaded.repo
            entry.reports = loaded.reports
            entry.baseBranches = loaded.baseBranches
            entry.problem = nil
        case .missing:
            entry = Entry(problem: .missing)
        case let .failed(message):
            entry = Entry(problem: .failed(message))
        }
        entries[path] = entry
        // Rows only appear with their verdict, so a Blocked branch is never selectable, even for a moment.
        picks = picks.filter { pick in
            pick.repo != path || entry.reports[pick.branch].map { $0.verdict != .blocked } ?? false
        }
    }

    /// One entry per main repo folder, in pinned order. A folder that is gone keeps its path so it can be reported.
    private nonisolated static func resolve(_ locals: [(nameWithOwner: String, path: String)]) -> [GardenRepo] {
        var seen = Set<URL>()
        return locals.compactMap { nameWithOwner, path in
            let folder = URL(fileURLWithPath: path)
            let main: URL = switch RepoLocator.locate(folder) {
            case let .repo(repo), let .worktree(of: repo): repo
            case .parent, .notGit: RepoLocator.canonical(folder)
            }
            guard seen.insert(main).inserted else { return nil }
            return GardenRepo(path: main, nameWithOwner: nameWithOwner)
        }
    }

    private nonisolated static func load(
        _ path: URL, analyzer: BranchAnalyzer, onProgress: @escaping @Sendable (Progress) -> Void
    ) -> Outcome {
        guard FileManager.default.fileExists(atPath: path.path) else { return .missing }
        do {
            let repo = try RepoReader.read(at: path)
            onProgress(.repo(repo))
            let reports = analyzer.analyze(repo) { name, report in onProgress(.report(name, report)) }
            return .loaded(Loaded(repo: repo, reports: reports, baseBranches: analyzer.baseBranches(of: repo)))
        } catch {
            return .failed("\(error)")
        }
    }
}
