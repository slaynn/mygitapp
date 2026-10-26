import AppKit
import SwiftUI

/// Chronological story of the PR: description → reviews with the threads they opened (and every
/// reply inside them) → general comments, with pushes interleaved at their date.
struct ConversationTab: View {
    @Environment(AppState.self) private var app
    var pr: PRDetail
    var model: PRDetailModel
    var hideResolved: Bool

    var body: some View {
        let timeline = ReviewTimeline.build(reviews: pr.extra.reviews.nodes,
                                            threads: pr.extra.reviewThreads.nodes,
                                            items: pr.extra.timelineItems.nodes)
        LazyVStack(alignment: .leading, spacing: 14) {
            CommentCard(author: pr.summary.author, date: pr.summary.createdAt, url: pr.summary.url,
                        markdown: pr.extra.body, action: "a ouvert la PR", emptyText: "Pas de description.")
            ForEach(timeline) { entry in
                switch entry {
                case .review(let group):
                    ReviewCard(group: group, model: model, hideResolved: hideResolved)
                case .orphanThread(let thread):
                    if !(hideResolved && thread.isResolved) {
                        ReviewThreadView(thread: thread, model: model)
                    }
                case .comment(let comment):
                    CommentCard(author: comment.author, date: comment.createdAt, url: comment.url,
                                markdown: comment.body, action: "a commenté")
                case .commits(let commits):
                    PushedCommits(commits: commits)
                case .event(let type, let event):
                    EventLine(type: type, event: event)
                }
            }
            // `viewerCanDeleteHeadRef` is only nil in caches older than the field, where a missing `headRef` means nothing.
            if pr.summary.state != "OPEN" && pr.extra.headRef == nil && pr.extra.headRepository != nil
                && pr.extra.viewerCanDeleteHeadRef != nil {
                DeletedBranchBanner(branch: pr.summary.headRefName, busy: model.busy.contains("branch")) {
                    Task { await model.restoreHeadBranch(app: app) }
                }
            }
            if pr.summary.state != "MERGED" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ajouter un commentaire").font(.system(size: 12.5, weight: .semibold))
                    Composer(placeholder: "Commentaire (markdown)…", submitLabel: "Commenter") { text in
                        await model.comment(text, app: app)
                    }
                }
                .card(padding: 14)
                .padding(.top, 6)
            }
        }
    }
}

/// GitHub's end-of-conversation note once the head branch is gone, with its "Restore branch" button.
private struct DeletedBranchBanner: View {
    var branch: String
    var busy: Bool
    var restore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text("La branche").foregroundStyle(.secondary)
            BranchChip(name: branch)
            Text("a été supprimée.").foregroundStyle(.secondary)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Restaurer la branche", action: restore).disabled(busy)
        }
        .font(.system(size: 12))
        .card(padding: 12)
        .padding(.top, 6)
    }
}

struct AuthorLine: View {
    var author: GHActor?
    var action: String
    var date: Date
    var url: URL?

    var body: some View {
        HStack(spacing: 7) {
            Avatar(url: author?.avatarUrl, size: 20)
            Text(author?.login ?? "ghost").font(.system(size: 12.5, weight: .semibold))
            Text(action).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(date.shortAgo).font(.system(size: 12)).foregroundStyle(.secondary)
                .help(date.formatted(date: .abbreviated, time: .shortened))
            Spacer()
            if let url {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Ouvrir sur GitHub")
            }
        }
    }
}

struct CommentCard: View {
    var author: GHActor?
    var date: Date
    var url: URL
    var markdown: String
    var action: String
    var emptyText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuthorLine(author: author, action: action, date: date, url: url)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.raised)
            Divider()
            Group {
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(emptyText ?? "").foregroundStyle(.secondary).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownBody(markdown: markdown)
                }
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .card()
    }
}

/// A review: its verdict, its summary body and, nested underneath, the threads it opened.
struct ReviewCard: View {
    var group: ReviewGroup
    var model: PRDetailModel
    var hideResolved: Bool
    @State private var bodyExpanded: Bool?

    var body: some View {
        let review = group.review
        let visible = group.threads.filter { !(hideResolved && $0.isResolved) }
        let hidden = group.threads.count - visible.count
        let hasBody = !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AuthorLine(author: review.author, action: verb(review.state), date: review.submittedAt ?? review.createdAt, url: review.url)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 6) {
                    stateBadge(review.state)
                    if !group.threads.isEmpty {
                        Badge(text: "\(group.threads.filter { !$0.isResolved }.count)/\(group.threads.count) ouverts",
                              color: group.threads.allSatisfy(\.isResolved) ? Theme.green : Theme.orange)
                    }
                }
                .padding(.trailing, 28)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.raised)

            if hasBody {
                Divider()
                // Long bot summaries collapse once their threads are all addressed.
                let expanded = bodyExpanded ?? !(group.threads.allSatisfy(\.isResolved) && !group.threads.isEmpty)
                VStack(alignment: .leading, spacing: 6) {
                    if expanded {
                        MarkdownBody(markdown: review.body)
                    }
                    Button(expanded ? "Réduire" : "Afficher le résumé de la review") { bodyExpanded = !expanded }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(14)
            }

            if !group.threads.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visible) { thread in
                        ReviewThreadView(thread: thread, model: model)
                    }
                    if hidden > 0 {
                        Text("\(hidden) thread(s) résolu(s) masqué(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .card()
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(stateColor(review.state)).frame(width: 2).padding(.vertical, 8)
        }
    }

    private func verb(_ state: String) -> String {
        switch state {
        case "APPROVED": "a approuvé"
        case "CHANGES_REQUESTED": "demande des changements"
        case "DISMISSED": "review rejetée"
        default: "a reviewé"
        }
    }

    @ViewBuilder private func stateBadge(_ state: String) -> some View {
        switch state {
        case "APPROVED": Badge(text: "Approved", color: Theme.green)
        case "CHANGES_REQUESTED": Badge(text: "Changes requested", color: Theme.red)
        case "DISMISSED": Badge(text: "Dismissed")
        default: Badge(text: "Commented", color: Theme.blue)
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "APPROVED": Theme.green
        case "CHANGES_REQUESTED": Theme.red
        default: Theme.blue.opacity(0.6)
        }
    }
}

struct PushedCommits: View {
    var commits: [CommitInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle").foregroundStyle(.secondary)
                Text(commits.count == 1 ? "1 commit poussé" : "\(commits.count) commits poussés")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 14)
            ForEach(commits) { commit in
                CommitRow(commit: commit, compact: true)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EventLine: View {
    var type: String
    var event: SimpleEvent

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(event.actor?.login ?? "ghost").fontWeight(.medium)
            Text(text).foregroundStyle(.secondary)
            Text(event.createdAt.shortAgo).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .padding(.leading, 14)
    }

    private var text: String {
        switch type {
        case "MergedEvent": "a mergé la PR"
        case "ClosedEvent": "a fermé la PR"
        case "ReopenedEvent": "a rouvert la PR"
        case "ReadyForReviewEvent": "a marqué la PR prête pour review"
        case "HeadRefDeletedEvent": "a supprimé la branche"
        case "HeadRefRestoredEvent": "a restauré la branche"
        case "HeadRefForcePushedEvent":
            "a force-push \(event.beforeCommit?.abbreviatedOid ?? "?") → \(event.afterCommit?.abbreviatedOid ?? "?")"
        default: type
        }
    }

    private var symbol: String {
        switch type {
        case "MergedEvent": "arrow.triangle.merge"
        case "ClosedEvent": "xmark.circle"
        case "ReopenedEvent": "arrow.uturn.backward.circle"
        case "HeadRefForcePushedEvent": "arrow.up.forward.circle"
        case "HeadRefDeletedEvent": "trash"
        case "HeadRefRestoredEvent": "arrow.triangle.branch"
        default: "eye"
        }
    }

    private var color: Color {
        switch type {
        case "MergedEvent": Theme.purple
        case "ClosedEvent": Theme.red
        default: .secondary
        }
    }
}
