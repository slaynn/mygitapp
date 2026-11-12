import Foundation
import Observation

/// PR screen state plus the light write actions. Each action updates the UI optimistically,
/// then refetches so the screen reflects what GitHub actually recorded.
@MainActor @Observable
final class PRDetailModel {
    let ref: PRRef
    let detail = Loader<PRDetail>()
    let files = Loader<[PRFile]>()
    let reviewers = Loader<ReviewerCandidates>()
    var actionError: String?
    var busy: Set<String> = []

    init(ref: PRRef) {
        self.ref = ref
    }

    func reload(_ app: AppState) async {
        guard let client = app.client else { return }
        await detail.load(ref.detailCacheKey) { [ref] in try await client.pullRequest(ref) }
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

    /// Starts a thread on one line of the diff, published right away like GitHub's "Add single comment".
    /// The reload brings the new thread back, anchored to its line in the Files tab.
    func commentOnLine(path: String, _ target: CommentTarget, body: String, app: AppState) async -> Bool {
        guard let pr = detail.value else { return false }
        return await perform("line-comment", app) { [ref] client in
            try await client.restSend("POST", "repos/\(ref.owner)/\(ref.name)/pulls/\(ref.number)/comments",
                                      body: ["body": body, "commit_id": pr.extra.headRefOid, "path": path,
                                             "line": target.line, "side": target.side])
        }
    }

    // MARK: Review

    /// The viewer's review in progress. GitHub keeps it pending, visible only to them, until it is submitted,
    /// so it survives restarts and is shared with github.com.
    var pendingReview: Review? { detail.value?.extra.reviews.nodes.first { $0.state == "PENDING" } }

    var pendingThreads: [ReviewThread] {
        detail.value?.extra.reviewThreads.nodes.filter(isPending) ?? []
    }

    func isPending(_ thread: ReviewThread) -> Bool {
        guard let id = pendingReview?.id else { return false }
        return thread.root?.pullRequestReview?.id == id
    }

    func startReview(app: AppState) async -> Bool {
        guard let pr = detail.value else { return false }
        return await perform("review", app) { client in
            try await client.mutate(Queries.startReview, ["pr": pr.summary.id, "commit": pr.extra.headRefOid])
        }
    }

    /// Adds a line comment to the pending review, starting the review with it when there is none yet.
    func addReviewComment(path: String, _ target: CommentTarget, body: String, app: AppState) async -> Bool {
        guard let pr = detail.value else { return false }
        let pending = pendingReview?.id
        return await perform("review", app) { client in
            let thread: [String: Any] = ["path": path, "line": target.line, "side": target.side, "body": body]
            if let pending {
                try await client.mutate(Queries.addReviewThread, thread.merging(["review": pending]) { $1 })
            } else {
                try await client.mutate(Queries.startReview, ["pr": pr.summary.id, "commit": pr.extra.headRefOid,
                                                              "threads": [thread]])
            }
        }
    }

    /// Publishes the pending review at once: its comments, `body`, and `event` (COMMENT, APPROVE or REQUEST_CHANGES).
    func submitReview(event: String, body: String, app: AppState) async -> Bool {
        guard let review = pendingReview else { return false }
        return await perform("review", app) { client in
            try await client.mutate(Queries.submitReview, ["review": review.id, "event": event,
                                                           "body": body.isEmpty ? nil : body])
        }
    }

    /// Drops the pending review with every comment in it.
    func discardReview(app: AppState) async -> Bool {
        guard let review = pendingReview else { return false }
        return await perform("review", app) { client in
            try await client.mutate(Queries.deleteReview, ["review": review.id])
        }
    }

    /// Removes a comment from the pending review; its thread goes with it.
    func deletePendingComment(_ thread: ReviewThread, app: AppState) async {
        guard let comment = thread.root else { return }
        _ = await perform(thread.id, app) { client in
            try await client.mutate(Queries.deleteReviewComment, ["id": comment.id])
        }
    }

    // MARK: PR

    func comment(_ body: String, app: AppState) async -> Bool {
        guard let pr = detail.value else { return false }
        return await perform("comment", app) { client in
            try await client.mutate(Queries.addComment, ["subject": pr.summary.id, "body": body])
        }
    }

    func merge(method: String, app: AppState) async {
        guard let pr = detail.value else { return }
        let ok = await perform("merge", app) { client in
            try await client.mutate(Queries.merge, ["pr": pr.summary.id, "method": method])
        }
        if ok { app.refresh() }
    }

    /// Draft ⇄ ready for review.
    func setDraft(_ draft: Bool, app: AppState) async {
        guard let pr = detail.value else { return }
        let ok = await perform("draft", app) { client in
            try await client.mutate(draft ? Queries.convertToDraft : Queries.markReadyForReview, ["pr": pr.summary.id])
        }
        if ok { app.refresh() }
    }

    /// GitHub's "Delete branch" once the PR is merged or closed.
    func deleteHeadBranch(app: AppState) async {
        guard let ref = detail.value?.extra.headRef else { return }
        _ = await perform("branch", app) { client in
            try await client.mutate(Queries.deleteRef, ["ref": ref.id])
        }
    }

    /// Puts the deleted head branch back at the PR's last commit.
    func restoreHeadBranch(app: AppState) async {
        guard let pr = detail.value, let repo = pr.extra.headRepository else { return }
        _ = await perform("branch", app) { client in
            try await client.mutate(Queries.restoreRef, ["repo": repo.id, "name": "refs/heads/\(pr.summary.headRefName)",
                                                         "oid": pr.extra.headRefOid])
        }
    }

    // MARK: Reviewers

    func loadReviewers(_ app: AppState) async {
        guard let client = app.client else { return }
        let author = detail.value?.summary.author?.login
        await reviewers.load("reviewers-\(ref.id)") { [ref] in try await client.reviewerCandidates(ref, author: author) }
    }

    /// Users matching `text` on GitHub's side, for repos with more users than were loaded.
    func searchReviewers(_ text: String, app: AppState) async -> [ReviewerCandidate] {
        guard let client = app.client else { return [] }
        let author = detail.value?.summary.author?.login
        return (try? await client.reviewerCandidates(ref, author: author, query: text, maxPages: 1).candidates) ?? []
    }

    func requestReview(from candidate: ReviewerCandidate, app: AppState) async {
        guard let pr = detail.value else { return }
        let reviewer = PRDetailExtra.ReviewRequest.Reviewer(
            login: candidate.isTeam ? nil : candidate.handle, name: candidate.isTeam ? candidate.name : nil,
            slug: candidate.isTeam ? candidate.handle : nil, avatarUrl: candidate.avatarUrl)
        detail.value?.extra.reviewRequests.nodes.append(.init(requestedReviewer: reviewer))
        let ok = await perform("reviewers", app) { client in
            try await client.mutate(Queries.requestReviews, ["pr": pr.summary.id,
                                                             "users": candidate.isTeam ? [] : [candidate.id],
                                                             "teams": candidate.isTeam ? [candidate.id] : []])
        }
        if !ok { detail.value?.extra.reviewRequests.nodes.removeAll { $0.requestedReviewer == reviewer } }
    }

    /// GraphQL can only add review requests; removing one goes through REST.
    func removeReviewRequest(_ reviewer: PRDetailExtra.ReviewRequest.Reviewer, app: AppState) async {
        let removed = detail.value?.extra.reviewRequests.nodes.filter { $0.requestedReviewer == reviewer } ?? []
        // Teams are removed by slug, which only a detail cache older than the field lacks, until the reload.
        guard let handle = reviewer.isTeam ? reviewer.slug : reviewer.login else { return }
        detail.value?.extra.reviewRequests.nodes.removeAll { $0.requestedReviewer == reviewer }
        let ok = await perform("reviewers", app) { [ref] client in
            try await client.restSend("DELETE", "repos/\(ref.owner)/\(ref.name)/pulls/\(ref.number)/requested_reviewers",
                                      body: [reviewer.isTeam ? "team_reviewers" : "reviewers": [handle]])
        }
        if !ok { detail.value?.extra.reviewRequests.nodes += removed }
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
