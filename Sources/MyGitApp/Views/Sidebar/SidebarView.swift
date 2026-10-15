import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    /// Lowercased owners whose section is collapsed, comma-separated.
    @AppStorage("collapsedWorkspaces") private var collapsedRaw = ""

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

            if app.store.pinned.isEmpty {
                Section("Repos") {
                    Button { app.isManageReposOpen = true } label: {
                        Label("Ajouter des repos…", systemImage: "plus.circle")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            ForEach(app.store.groups) { group in
                Section(isExpanded: expandedBinding(group)) {
                    ForEach(group.repos) { repo in
                        PinnedRepoRow(repo: repo, summary: app.summary(for: repo.nameWithOwner))
                            .tag(SidebarItem.repo(repo.nameWithOwner))
                            .contextMenu { contextMenu(for: repo) }
                    }
                    .onMove { app.store.move(in: group, from: $0, to: $1) }
                } header: {
                    WorkspaceHeader(group: group,
                                    avatar: group.repos.lazy.compactMap { app.summary(for: $0.nameWithOwner)?.owner.avatarUrl }.first,
                                    isViewer: group.owner.caseInsensitiveCompare(app.viewer?.login ?? "") == .orderedSame)
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
        .frame(height: Theme.topBarHeight)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            UpdateBanner()
            if let error = app.sidebarError {
                Text(error).font(.caption).foregroundStyle(Theme.yellow).lineLimit(2)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 6) {
                    Circle().fill(app.sidebarError == nil ? Theme.green : Theme.yellow).frame(width: 6, height: 6)
                    Text(syncText).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("MyGitApp \(Updater.shared.currentVersion)")
                    Spacer()
                    Button { app.isManageReposOpen = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Gérer les repos (⇧⌘P)")
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

    private func expandedBinding(_ group: RepoGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(group.id) },
            set: { expanded in
                var set = collapsed
                if expanded { set.remove(group.id) } else { set.insert(group.id) }
                collapsedRaw = set.sorted().joined(separator: ",")
            })
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

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

/// Appears once a newer release is downloaded and verified.
private struct UpdateBanner: View {
    private var updater: Updater { .shared }

    var body: some View {
        switch updater.state {
        case .downloading(let version):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Téléchargement de la \(version)…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .ready(let version):
            Button { updater.installAndRelaunch() } label: {
                Label("Redémarrer pour passer en \(version)", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help("Sinon, la mise à jour s'installe quand tu quittes l'app.")
        default:
            EmptyView()
        }
    }
}

private struct WorkspaceHeader: View {
    var group: RepoGroup
    var avatar: URL?
    var isViewer: Bool

    var body: some View {
        HStack(spacing: 6) {
            Avatar(url: avatar, size: 14, square: !isViewer)
            Text(group.owner)
            if isViewer { Text("perso").foregroundStyle(.tertiary) }
        }
    }
}

private struct PinnedRepoRow: View {
    var repo: PinnedRepo
    var summary: RepoSummary?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: repo.localPath != nil ? "folder" : "book.closed")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(repo.name).lineLimit(1)
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
