import AppKit
import SwiftUI

struct PRDetailView: View {
    @Environment(AppState.self) private var app
    @State private var model: PRDetailModel
    @State private var tab = Tab(rawValue: DebugHooks.initialPRTab ?? "") ?? .conversation
    @AppStorage("hideResolvedThreads") private var hideResolved = true
    @State private var pendingMerge: String?
    @State private var confirmApprove = false

    enum Tab: String, Hashable { case conversation, threads, files, checks }
    private struct LoadKey: Hashable { var ref: PRRef; var tick: Int }

    init(ref: PRRef) {
        _model = State(initialValue: PRDetailModel(ref: ref))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pr = model.detail.value {
                header(pr)
                Divider()
                tabBar(pr)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = model.actionError { ErrorBanner(message: error) }
                        if let error = model.detail.error { ErrorBanner(message: error) }
                        content(pr)
                    }
                    .padding(20)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else if let error = model.detail.error {
                ErrorBanner(message: error).padding(24)
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle("\(model.ref.nameWithOwner) #\(model.ref.number)")
        .task(id: LoadKey(ref: model.ref, tick: app.refreshTick)) {
            await model.reload(app)
            if tab == .files { await model.loadFiles(app) }
        }
        .onChange(of: tab) { _, new in
            if new == .files, model.files.value == nil || model.files.loadedKey == nil {
                Task { await model.loadFiles(app) }
            }
        }
        .confirmationDialog("Merger cette pull request ?", isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } })) {
            if let method = pendingMerge {
                Button(mergeLabel(method)) { Task { await model.merge(method: method, app: app) } }
            }
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog("Approuver cette pull request ?", isPresented: $confirmApprove) {
            Button("Approuver") { Task { await model.approve(app: app) } }
            Button("Annuler", role: .cancel) {}
        }
    }

    // MARK: Header

    private func header(_ pr: PRDetail) -> some View {
        let s = pr.summary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PRStateIcon(state: s.state, isDraft: s.isDraft).font(.system(size: 17))
                Text(s.title).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
                Text("#\(s.number)").font(.system(size: 19)).foregroundStyle(.secondary)
                Spacer()
                actions(pr)
            }
            HStack(spacing: 8) {
                stateBadge(s)
                Avatar(url: s.author?.avatarUrl, size: 16)
                Text(s.author?.login ?? "ghost").fontWeight(.medium)
                Text("veut merger dans").foregroundStyle(.secondary)
                BranchChip(name: s.baseRefName)
                Text("depuis").foregroundStyle(.secondary)
                BranchChip(name: s.headRefName)
                Text("· \(s.createdAt.shortAgo)").foregroundStyle(.secondary)
                DiffStat(additions: s.additions, deletions: s.deletions)
                ReviewDecisionBadge(decision: s.reviewDecision)
                Spacer()
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private func stateBadge(_ s: PRSummary) -> some View {
        switch s.state {
        case "MERGED": Badge(text: "Merged", color: Theme.purple, filled: true)
        case "CLOSED": Badge(text: "Closed", color: Theme.red, filled: true)
        default: s.isDraft ? Badge(text: "Draft", color: Theme.gray, filled: true) : Badge(text: "Open", color: Theme.green, filled: true)
        }
    }

    @ViewBuilder private func actions(_ pr: PRDetail) -> some View {
        let s = pr.summary
        HStack(spacing: 8) {
            if model.busy.contains("approve") || model.busy.contains("merge") { ProgressView().controlSize(.small) }
            if s.state == "OPEN" && !pr.extra.viewerDidAuthor {
                Button { confirmApprove = true } label: { Label("Approuver", systemImage: "checkmark") }
            }
            if s.state == "OPEN" && !s.isDraft {
                Menu {
                    let repo = pr.extra.repository
                    if repo.squashMergeAllowed ?? true { Button(mergeLabel("SQUASH")) { pendingMerge = "SQUASH" } }
                    if repo.mergeCommitAllowed ?? true { Button(mergeLabel("MERGE")) { pendingMerge = "MERGE" } }
                    if repo.rebaseMergeAllowed ?? true { Button(mergeLabel("REBASE")) { pendingMerge = "REBASE" } }
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help(mergeHelp(pr))
            }
            Link(destination: s.url) { Label("GitHub", systemImage: "arrow.up.right") }
                .buttonStyle(.bordered)
        }
        .controlSize(.small)
    }

    private func mergeLabel(_ method: String) -> String {
        switch method {
        case "SQUASH": "Squash and merge"
        case "REBASE": "Rebase and merge"
        default: "Create a merge commit"
        }
    }

    private func mergeHelp(_ pr: PRDetail) -> String {
        switch pr.extra.mergeStateStatus {
        case "CLEAN": "Prête à merger"
        case "BLOCKED": "Bloquée par les règles de protection de branche"
        case "BEHIND": "La branche est en retard sur la base"
        case "DIRTY": "Conflits à résoudre"
        case "UNSTABLE": "Checks en échec ou en cours"
        default: pr.extra.mergeStateStatus.lowercased()
        }
    }

    // MARK: Tabs

    private func tabBar(_ pr: PRDetail) -> some View {
        let threads = pr.extra.reviewThreads.nodes
        let unresolved = threads.filter { !$0.isResolved }.count
        let checks = pr.extra.checks
        let failing = checks.filter { $0.status == .failure }.count
        return HStack(spacing: 2) {
            tabButton("Conversation", .conversation, count: nil)
            tabButton("Threads", .threads, count: unresolved, highlight: unresolved > 0)
            tabButton("Files", .files, count: pr.extra.changedFiles)
            tabButton("Checks", .checks, count: failing > 0 ? failing : checks.count, highlight: failing > 0, highlightColor: Theme.red)
            Spacer()
            if tab == .conversation || tab == .threads {
                Toggle("Masquer les résolus", isOn: $hideResolved)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            if model.detail.isLoading { ProgressView().controlSize(.small).padding(.leading, 8) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func tabButton(_ title: String, _ value: Tab, count: Int?, highlight: Bool = false, highlightColor: Color = Theme.orange) -> some View {
        Button {
            tab = value
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((highlight ? highlightColor : Color.white).opacity(highlight ? 0.2 : 0.08), in: Capsule())
                        .foregroundStyle(highlight ? highlightColor : .secondary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tab == value ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func content(_ pr: PRDetail) -> some View {
        switch tab {
        case .conversation:
            ConversationTab(pr: pr, model: model, hideResolved: hideResolved)
        case .threads:
            ThreadsTab(pr: pr, model: model, hideResolved: hideResolved)
        case .files:
            FilesTab(model: model, threads: pr.extra.reviewThreads.nodes)
        case .checks:
            ChecksTab(checks: pr.extra.checks, prURL: pr.summary.url)
        }
    }
}

struct BranchChip: View {
    var name: String
    var body: some View {
        Button { Pasteboard.copy(name) } label: {
            Text(name)
                .font(Theme.monoSmall)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(Theme.blue)
        }
        .buttonStyle(.plain)
        .help("Copier le nom de la branche")
    }
}
