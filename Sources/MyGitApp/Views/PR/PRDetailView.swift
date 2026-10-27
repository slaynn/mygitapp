import AppKit
import SwiftUI

struct PRDetailView: View {
    @Environment(AppState.self) private var app
    @State private var model: PRDetailModel
    @State private var tab = Tab(rawValue: DebugHooks.initialPRTab ?? "") ?? .conversation
    @AppStorage("hideResolvedThreads") private var hideResolved = true
    @State private var pendingMerge: String?
    @State private var confirmApprove = false
    @State private var confirmDeleteBranch = false

    enum Tab: String, Hashable { case conversation, threads, files, checks }
    private struct LoadKey: Hashable { var ref: PRRef; var tick: Int }

    init(ref: PRRef) {
        _model = State(initialValue: PRDetailModel(ref: ref))
    }

    var body: some View {
        // The list's summary draws the header right away; the detail fills in the rest.
        let summary = model.detail.value?.summary ?? app.knownSummaries[model.ref.id]
        let extra = model.detail.value?.extra
        VStack(spacing: 0) {
            if let summary {
                header(summary, extra: extra)
                Divider()
                tabBar(summary, extra: extra)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = model.actionError { ErrorBanner(message: error) }
                        if let error = model.detail.error { ErrorBanner(message: error) }
                        if let pr = model.detail.value {
                            content(pr)
                        } else if model.detail.error == nil {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                        }
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
        .confirmationDialog("Supprimer la branche \(summary?.headRefName ?? "") ?", isPresented: $confirmDeleteBranch) {
            Button("Supprimer la branche", role: .destructive) { Task { await model.deleteHeadBranch(app: app) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Elle pourra être restaurée depuis la conversation.")
        }
    }

    // MARK: Header

    private func header(_ s: PRSummary, extra: PRDetailExtra?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PRStateIcon(state: s.state, isDraft: s.isDraft).font(.system(size: 17))
                Text(s.title).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
                PRNumberButton(ref: s.ref)
                Spacer()
                actions(s, extra: extra)
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
            if let pr = model.detail.value, s.state == "OPEN" || !pr.extra.reviewRequests.nodes.isEmpty {
                ReviewersField(pr: pr, model: model)
            }
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

    /// Approve / merge need the detail (authorship, allowed merge methods), so they appear once it loads.
    @ViewBuilder private func actions(_ s: PRSummary, extra: PRDetailExtra?) -> some View {
        HStack(spacing: 8) {
            if model.busy.contains("approve") || model.busy.contains("merge") || model.busy.contains("draft") || model.busy.contains("branch") {
                ProgressView().controlSize(.small)
            }
            if let extra, s.state == "OPEN" && !extra.viewerDidAuthor {
                Button { confirmApprove = true } label: { Label("Approuver", systemImage: "checkmark") }
            }
            if let extra, s.state == "OPEN" && s.isDraft && (extra.viewerDidAuthor || extra.viewerCanUpdate) {
                Button { Task { await model.setDraft(false, app: app) } } label: {
                    Label("Prête pour review", systemImage: "eye")
                }
                .disabled(model.busy.contains("draft"))
                .help("Sortir la PR du mode brouillon pour demander les reviews")
            }
            if let extra, s.state == "OPEN" && !s.isDraft {
                Menu {
                    let repo = extra.repository
                    if repo.squashMergeAllowed ?? true { Button(mergeLabel("SQUASH")) { pendingMerge = "SQUASH" } }
                    if repo.mergeCommitAllowed ?? true { Button(mergeLabel("MERGE")) { pendingMerge = "MERGE" } }
                    if repo.rebaseMergeAllowed ?? true { Button(mergeLabel("REBASE")) { pendingMerge = "REBASE" } }
                    if extra.viewerDidAuthor || extra.viewerCanUpdate {
                        Divider()
                        Button("Repasser en brouillon") { Task { await model.setDraft(true, app: app) } }
                    }
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help(mergeHelp(extra))
            }
            if let extra, s.state != "OPEN" && extra.headRef != nil && extra.viewerCanDeleteHeadRef == true {
                Button { confirmDeleteBranch = true } label: { Label("Supprimer la branche", systemImage: "trash") }
                    .help("La branche \(s.headRefName) peut être supprimée en toute sécurité")
            }
            Link(destination: s.url) { Label("GitHub", systemImage: "arrow.up.right") }
                .buttonStyle(.bordered)
        }
    }

    private func mergeLabel(_ method: String) -> String {
        switch method {
        case "SQUASH": "Squash and merge"
        case "REBASE": "Rebase and merge"
        default: "Create a merge commit"
        }
    }

    private func mergeHelp(_ extra: PRDetailExtra) -> String {
        switch extra.mergeStateStatus {
        case "CLEAN": "Prête à merger"
        case "BLOCKED": "Bloquée par les règles de protection de branche"
        case "BEHIND": "La branche est en retard sur la base"
        case "DIRTY": "Conflits à résoudre"
        case "UNSTABLE": "Checks en échec ou en cours"
        default: extra.mergeStateStatus.lowercased()
        }
    }

    // MARK: Tabs

    private func tabBar(_ s: PRSummary, extra: PRDetailExtra?) -> some View {
        let unresolved = extra.map { $0.reviewThreads.nodes.filter { !$0.isResolved }.count } ?? s.unresolvedCount
        let checks = extra?.checks
        let failing = checks?.filter { $0.status == .failure }.count ?? 0
        return HStack(spacing: 2) {
            tabButton("Conversation", .conversation, count: nil)
            tabButton("Threads", .threads, count: unresolved, highlight: unresolved > 0)
            tabButton("Files", .files, count: extra?.changedFiles)
            tabButton("Checks", .checks, count: checks.map { failing > 0 ? failing : $0.count },
                      highlight: failing > 0, highlightColor: Theme.red)
            Spacer()
            if tab == .conversation || tab == .threads {
                Toggle("Masquer les résolus", isOn: $hideResolved)
                    .toggleStyle(.checkbox)
            }
            if model.detail.isLoading { ProgressView().controlSize(.small).padding(.leading, 8) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func tabButton(_ title: String, _ value: Tab, count: Int?, highlight: Bool = false, highlightColor: Color = Theme.orange) -> some View {
        TabPill(title: title, count: count, isSelected: tab == value, highlight: highlight ? highlightColor : nil) { tab = value }
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

/// `#742` in the PR header: click copies it, right-click offers the other formats.
struct PRNumberButton: View {
    var ref: PRRef
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button { copy("#\(ref.number)") } label: {
            HStack(spacing: 5) {
                Text("#\(ref.number)").font(.system(size: 19))
                if copied {
                    Label("Copié", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.green)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 4)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Copier #\(ref.number)")
        .contextMenu {
            Button("Copier #\(ref.number)") { copy("#\(ref.number)") }
            Button("Copier \(ref.nameWithOwner)#\(ref.number)") { copy("\(ref.nameWithOwner)#\(ref.number)") }
            Button("Copier l'URL") { copy(ref.htmlURL.absoluteString) }
        }
    }

    private func copy(_ value: String) {
        Pasteboard.copy(value)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.3)) { copied = false }
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
