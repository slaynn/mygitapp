import Foundation

/// A pull request list fetched page by page: the first page is cached like any `Loader`, the next ones are
/// appended on demand.
@MainActor @Observable
final class PRPager {
    let first = Loader<PRPage>()
    private(set) var loadingMore = false
    private var fetch: ((String?) async throws -> PRPage)?

    var page: PRPage? { first.value }
    var hasMore: Bool { page?.pageInfo.hasNextPage ?? false }

    /// `fetch` gets the cursor to read after, `nil` for the first page.
    func load(_ key: String, fetch: @escaping (String?) async throws -> PRPage) async {
        self.fetch = fetch
        await first.load(key) { try await fetch(nil) }
    }

    func loadMore() {
        guard let fetch, let cursor = page?.pageInfo.endCursor, !loadingMore else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            do {
                let next = try await fetch(cursor)
                // A refresh may have replaced the list meanwhile: only append to the page this cursor came from.
                guard first.value?.pageInfo.endCursor == cursor else { return }
                first.value?.append(next)
            } catch {
                first.error = error.localizedDescription
            }
        }
    }
}
