import Foundation
import SwiftUI

extension PRRef {
    /// Disk cache key shared by the PR screen and the prefetcher.
    var detailCacheKey: String { "pr-\(id)" }
}

/// Warms the disk cache with the detail of PRs shown in lists, so opening one is instant.
/// A PR is skipped when its cached copy already matches the list's `updatedAt`.
@MainActor
final class PRPrefetcher {
    static let shared = PRPrefetcher()
    private let maxConcurrent = 3
    private let maxPerBatch = 20
    private var inFlight: Set<String> = []
    /// ref id → `updatedAt` of the copy known to be on disk.
    private var cached: [String: Date] = [:]

    /// Fire-and-forget: keeps running when the list that triggered it is navigated away from.
    func enqueue(_ prs: [PRSummary], client: GitHubClient) {
        let candidates = Array(prs.prefix(maxPerBatch)).filter { pr in
            !inFlight.contains(pr.ref.id) && cached[pr.ref.id] != pr.updatedAt
        }
        guard !candidates.isEmpty else { return }
        candidates.forEach { inFlight.insert($0.ref.id) }

        Task {
            let stale = await Task.detached(priority: .utility) {
                candidates.filter { pr in
                    DiskCache.shared.read(pr.ref.detailCacheKey, as: PRDetail.self)?.summary.updatedAt != pr.updatedAt
                }
            }.value
            for pr in candidates where !stale.contains(where: { $0.id == pr.id }) {
                cached[pr.ref.id] = pr.updatedAt
                inFlight.remove(pr.ref.id)
            }

            await withTaskGroup(of: Void.self) { group in
                var queue = stale.makeIterator()
                for _ in 0..<maxConcurrent {
                    guard let pr = queue.next() else { break }
                    group.addTask { await self.fetch(pr, client: client) }
                }
                while await group.next() != nil {
                    guard let pr = queue.next() else { continue }
                    group.addTask { await self.fetch(pr, client: client) }
                }
            }
        }
    }

    private func fetch(_ pr: PRSummary, client: GitHubClient) async {
        defer { inFlight.remove(pr.ref.id) }
        guard let detail = try? await client.pullRequest(pr.ref) else { return }
        DiskCache.shared.write(detail, key: pr.ref.detailCacheKey)
        cached[pr.ref.id] = detail.summary.updatedAt
    }
}

private struct PrefetchModifier: ViewModifier {
    @Environment(AppState.self) private var app
    var prs: [PRSummary]

    func body(content: Content) -> some View {
        content.task(id: prs.map { "\($0.id)@\($0.updatedAt.timeIntervalSince1970)" }) {
            app.remember(prs)
            // Let the screen's own request go first.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let client = app.client else { return }
            PRPrefetcher.shared.enqueue(prs, client: client)
        }
    }
}

extension View {
    /// Remembers the summaries (instant PR header) and prefetches their detail in the background.
    func prefetching(_ prs: [PRSummary]) -> some View {
        modifier(PrefetchModifier(prs: prs))
    }
}
