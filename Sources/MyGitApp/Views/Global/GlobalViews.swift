import AppKit
import SwiftUI

/// Filter shared by the global lists: pinned repos only, or everything.
struct ScopeToggle: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        Picker("", selection: $app.showAllRepos) {
            Text("Repos épinglés").tag(false)
            Text("Tous les repos").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 230)
    }
}

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

struct PRSearchListView: View {
    var title: String
    var prs: [PRSummary]
    var empty: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: title, subtitle: "\(prs.count) ouverte(s)") { ScopeToggle() }
                PRList(prs: prs, empty: empty)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .navigationTitle(title)
    }
}

/// PRs grouped by repository, in a single card.
struct PRList: View {
    var prs: [PRSummary]
    var empty: String
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(prs.prefix($0)) } ?? prs
        VStack(alignment: .leading, spacing: 0) {
            if prs.isEmpty { EmptyStateText(text: empty) }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, pr in
                PRRowView(pr: pr, showRepo: true)
                if index < shown.count - 1 { Divider().opacity(0.4) }
            }
        }
        .card()
    }
}

struct HomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Bonjour \(app.viewer?.name?.split(separator: " ").first.map(String.init) ?? app.viewer?.login ?? "")",
                           subtitle: subtitle) { ScopeToggle() }
                    .padding(.horizontal, -24)

                if app.store.pinned.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Commence par choisir les repos à suivre.").font(.headline)
                        Text("Seuls les repos épinglés apparaissent dans la sidebar et filtrent les listes : tes vieux projets restent hors de vue.")
                            .foregroundStyle(.secondary)
                        Button("Choisir mes repos…") { app.isManageReposOpen = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .card(padding: 18)
                }

                section("Review requests", count: app.visibleReviewRequests.count) {
                    PRList(prs: app.visibleReviewRequests, empty: "Personne n'attend ta review.", limit: 8)
                }
                section("Mes pull requests", count: app.visibleMyPRs.count) {
                    PRList(prs: app.visibleMyPRs, empty: "Aucune PR ouverte.", limit: 8)
                }
                let unread = app.visibleNotifications.filter(\.unread)
                section("Notifications non lues", count: unread.count) {
                    NotificationList(notifications: Array(unread.prefix(6)), empty: "Inbox vide.")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Home")
    }

    private var subtitle: String {
        let unresolved = app.visibleMyPRs.reduce(0) { $0 + $1.unresolvedCount }
        var parts: [String] = []
        parts.append("\(app.visibleReviewRequests.count) review(s) à faire")
        if unresolved > 0 { parts.append("\(unresolved) thread(s) non résolu(s) sur tes PRs") }
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(count)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    @Environment(AppState.self) private var app
    @State private var onlyUnread = true

    var body: some View {
        let items = app.visibleNotifications.filter { !onlyUnread || $0.unread }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Inbox", subtitle: "\(app.visibleNotifications.filter(\.unread).count) non lue(s)") {
                    HStack(spacing: 12) {
                        Toggle("Non lues seulement", isOn: $onlyUnread).toggleStyle(.checkbox)
                        if items.contains(where: \.unread) {
                            Button("Tout marquer comme lu") { items.filter(\.unread).forEach(app.markRead) }
                                .help("Uniquement les notifications affichées")
                        }
                        ScopeToggle()
                    }
                    .controlSize(.small)
                }
                NotificationList(notifications: items, empty: "Rien de neuf.")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .navigationTitle("Inbox")
    }
}

struct NotificationList: View {
    var notifications: [GHNotification]
    var empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if notifications.isEmpty { EmptyStateText(text: empty) }
            ForEach(Array(notifications.enumerated()), id: \.element.id) { index, notification in
                NotificationRow(notification: notification)
                if index < notifications.count - 1 { Divider().opacity(0.4) }
            }
        }
        .card()
    }
}

private struct NotificationRow: View {
    @Environment(AppState.self) private var app
    var notification: GHNotification

    var body: some View {
        HoverRow(action: open) {
            HStack(spacing: 10) {
                Circle().fill(notification.unread ? Theme.blue : .clear).frame(width: 6, height: 6)
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.subject.title).font(.system(size: 13)).lineLimit(1)
                        .fontWeight(notification.unread ? .medium : .regular)
                    HStack(spacing: 6) {
                        Avatar(url: notification.repository.owner?.avatar_url, size: 12, square: true)
                        Text(notification.repository.full_name)
                        Text("· \(notification.updated_at.shortAgo)")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Badge(text: reason, color: reasonColor)
                if notification.unread {
                    Button { app.markRead(notification) } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Marquer comme lu")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .opacity(notification.unread ? 1 : 0.6)
        }
        .contextMenu {
            Button("Ouvrir sur GitHub") { NSWorkspace.shared.open(notification.htmlURL) }
            if notification.unread { Button("Marquer comme lu") { app.markRead(notification) } }
        }
    }

    private func open() {
        app.markRead(notification)
        if let pr = notification.pullRequest {
            app.open(pr)
        } else {
            NSWorkspace.shared.open(notification.htmlURL)
        }
    }

    private var symbol: String {
        switch notification.subject.type {
        case "PullRequest": "arrow.triangle.pull"
        case "Issue": "smallcircle.filled.circle"
        case "Release": "tag"
        case "Discussion": "bubble.left.and.bubble.right"
        case "CheckSuite": "checkmark.circle"
        case "Commit": "smallcircle.fill.circle"
        default: "bell"
        }
    }

    private var reason: String {
        switch notification.reason {
        case "review_requested": "Review demandée"
        case "mention", "team_mention": "Mention"
        case "author": "Auteur"
        case "comment": "Commentaire"
        case "assign": "Assigné"
        case "ci_activity": "CI"
        case "state_change": "État"
        case "subscribed", "manual": "Suivi"
        default: notification.reason
        }
    }

    private var reasonColor: Color {
        switch notification.reason {
        case "review_requested": Theme.orange
        case "mention", "team_mention", "assign": Theme.blue
        case "ci_activity": Theme.red
        default: Theme.gray
        }
    }
}
