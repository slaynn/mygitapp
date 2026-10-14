import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Inbox", systemImage: "tray")
                    .badge(app.visibleNotifications.filter(\.unread).count)
                    .tag(SidebarItem.inbox)
                Label("Pull requests", systemImage: "arrow.triangle.pull")
                    .badge(app.visibleMyPRs.count)
                    .tag(SidebarItem.pullRequests)
                Label("Review requests", systemImage: "eye")
                    .badge(app.visibleReviewRequests.count)
                    .tag(SidebarItem.reviewRequests)
            }

            Section {
                ForEach(app.store.pinned) { repo in
                    PinnedRepoRow(repo: repo, summary: app.summary(for: repo.nameWithOwner))
                        .tag(SidebarItem.repo(repo.nameWithOwner))
                        .contextMenu { contextMenu(for: repo) }
                }
                .onMove { app.store.move(from: $0, to: $1) }
                if app.store.pinned.isEmpty {
                    Button("Ajouter des repos…") { app.isManageReposOpen = true }
                        .buttonStyle(.link)
                }
            } header: {
                HStack {
                    Text("Pinned")
                    Spacer()
                    Button { app.isManageReposOpen = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("Gérer les repos (⇧⌘P)")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Avatar(url: app.viewer?.avatarUrl, size: 22)
            Text(app.viewer?.login ?? "").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { app.isCommandPaletteOpen = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rechercher (⌘K)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = app.sidebarError {
                Text(error).font(.caption).foregroundStyle(Theme.yellow).lineLimit(2)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 6) {
                    Circle().fill(app.sidebarError == nil ? Theme.green : Theme.yellow).frame(width: 6, height: 6)
                    Text(syncText).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Rafraîchir (⌘R)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var syncText: String {
        guard let last = SyncClock.shared.lastSync else { return "Synchronisation…" }
        let seconds = Int(Date.now.timeIntervalSince(last))
        return seconds < 60 ? "Synced \(seconds)s ago" : "Synced \(last.shortAgo) ago"
    }

    @ViewBuilder private func contextMenu(for repo: PinnedRepo) -> some View {
        Button("Ouvrir sur GitHub") { NSWorkspace.shared.open(repo.htmlURL) }
        if let path = repo.localPath {
            Divider()
            LocalOpenButtons(path: path)
        }
        Divider()
        Button("Retirer de la sidebar", role: .destructive) {
            if app.selection == .repo(repo.nameWithOwner) { app.selection = .home }
            app.store.remove(repo.nameWithOwner)
        }
    }
}

private struct PinnedRepoRow: View {
    var repo: PinnedRepo
    var summary: RepoSummary?

    var body: some View {
        HStack(spacing: 7) {
            Avatar(url: summary?.owner.avatarUrl, size: 16, square: true)
            Text(repo.name).lineLimit(1)
            if repo.localPath != nil {
                Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let summary {
                if summary.pullRequests.totalCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.pull").font(.system(size: 9))
                        Text("\(summary.pullRequests.totalCount)")
                    }
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 2) {
                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.orange)
                    Text(summary.stargazerCount.formatted())
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5))
        .help(repo.localPath.map { "\(repo.nameWithOwner)\n\($0)" } ?? repo.nameWithOwner)
    }
}

/// Finder / Terminal / editor shortcuts for a local clone.
struct LocalOpenButtons: View {
    var path: String

    private static let editors: [(name: String, bundleID: String)] = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Zed", "dev.zed.Zed"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]

    var body: some View {
        Button("Afficher dans le Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
        Button("Ouvrir dans le Terminal") { open(bundleID: "com.apple.Terminal") }
        ForEach(Self.editors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }, id: \.bundleID) { editor in
            Button("Ouvrir dans \(editor.name)") { open(bundleID: editor.bundleID) }
        }
    }

    private func open(bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
