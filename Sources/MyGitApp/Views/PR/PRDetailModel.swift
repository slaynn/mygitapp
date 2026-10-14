import Foundation
import Observation

/// PR screen state plus the light write actions. Each action updates the UI optimistically,
/// then refetches so the screen reflects what GitHub actually recorded.
@MainActor @Observable
final class PRDetailModel {
    let ref: PRRef
    let detail = Loader<PRDetail>()
    let files = Loader<[PRFile]>()
    var actionError: String?
    var busy: Set<String> = []

    init(ref: PRRef) {
        self.ref = ref
    }

    func reload(_ app: AppState) async {
        guard let client = app.client else { return }
        await detail.load("pr-\(ref.id)") { [ref] in try await client.pullRequest(ref) }
    }

    func loadFiles(_ app: AppState) async {
        guard let client = app.client else { return }
        await files.load("files-\(ref.id)") { [ref] in try await client.pullRequestFiles(ref) }
    }

    // MARK: Threads

    func reply(to thread: ReviewThread, body: String, app: AppState) async -> Bool {
        await perform(thread.id, app) { client in
            try await client.mutate(Queries.addReply, ["thread": thread.id, "body": body])
            self.updateThread(thread.id) { thread in
                let author = app.viewer.map { GHActor(login: $0.login, avatarUrl: $0.avatarUrl) }
                thread.comments.nodes.append(ReviewComment(
                    id: UUID().uuidString, author: author, body: body, createdAt: .now,
                    url: thread.root?.url ?? self.ref.htmlURL, diffHunk: "", outdated: false, pullRequestReview: nil))
            }
        }
    }

    func setResolved(_ thread: ReviewThread, _ resolved: Bool, app: AppState) async {
        updateThread(thread.id) { $0.isResolved = resolved }
        let ok = await perform(thread.id, app) { client in
            try await client.mutate(resolved ? Queries.resolveThread : Queries.unresolveThread, ["thread": thread.id])
        }
        if !ok { updateThread(thread.id) { $0.isResolved = !resolved } }
    }

    // MARK: PR

    func comment(_ body: String, app: AppState) async -> Bool {
        guard let pr = detail.value else { return false }
        return await perform("comment", app) { client in
            try await client.mutate(Queries.addComment, ["subject": pr.summary.id, "body": body])
        }
    }

    func approve(app: AppState) async {
        guard let pr = detail.value else { return }
        _ = await perform("approve", app) { client in
            try await client.mutate(Queries.approve, ["pr": pr.summary.id, "body": nil])
        }
    }

    func merge(method: String, app: AppState) async {
        guard let pr = detail.value else { return }
        let ok = await perform("merge", app) { client in
            try await client.mutate(Queries.merge, ["pr": pr.summary.id, "method": method])
        }
        if ok { app.refresh() }
    }

    // MARK: Helpers

    private func updateThread(_ id: String, _ change: (inout ReviewThread) -> Void) {
        guard let index = detail.value?.extra.reviewThreads.nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&detail.value!.extra.reviewThreads.nodes[index])
    }

    private func perform(_ key: String, _ app: AppState, _ action: @escaping (GitHubClient) async throws -> Void) async -> Bool {
        guard let client = app.client else { return false }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await action(client)
            actionError = nil
            await reload(app)
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }
}
