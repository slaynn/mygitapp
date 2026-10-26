import AppKit
import GitGardenerCore
import SwiftUI

private typealias Report = BranchAnalyzer.Report

/// Filters of the local branches screen.
struct GardenFilters {
    enum Location: CaseIterable {
        case localOnly, tracked, gone

        var label: String {
            switch self {
            case .localOnly: "Local uniquement"
            case .tracked: "Suivie"
            case .gone: "Origin supprimée"
            }
        }

        func matches(_ location: Repo.BranchLocation) -> Bool {
            switch (self, location) {
            case (.localOnly, .localOnly), (.gone, .gone), (.tracked, .tracked): true
            default: false
            }
        }
    }

    static let ages = [0, 30, 90, 180, 365]

    /// nil shows every branch that can be pruned: Blocked ones only appear when asked for.
    var verdict: SafetyVerdict?
    var location: Location?
    var minimumAgeInDays = 0
    var search = ""

    var isActive: Bool { verdict != nil || location != nil || minimumAgeInDays > 0 || !search.isEmpty }

    func matches(name: String, verdict reportVerdict: SafetyVerdict?) -> Bool {
        (verdict == nil ? reportVerdict != .blocked : verdict == reportVerdict)
            && (search.isEmpty || name.localizedCaseInsensitiveContains(search))
    }

    func matches(_ branch: Repo.Branch, verdict: SafetyVerdict?) -> Bool {
        matches(name: branch.name, verdict: verdict)
            && (location?.matches(branch.location) ?? true)
            && branch.lastCommitDate < Date().addingTimeInterval(-Double(minimumAgeInDays) * 86_400)
    }
}

/// Rows a repo shows once the filters are applied.
struct VisibleBranches {
    let rows: [Repo.Branch]
    let originOnly: [String]

    init(repo: Repo, reports: [String: BranchAnalyzer.Report], filters: GardenFilters) {
        rows = repo.branches.filter { filters.matches($0, verdict: reports[$0.name]?.verdict) }
        // Origin Only branches have no location nor local commit date to filter on.
        originOnly = filters.location == nil && filters.minimumAgeInDays == 0
            ? repo.originOnlyBranches.filter { filters.matches(name: $0, verdict: reports[$0]?.verdict) }
            : []
    }

    var isEmpty: Bool { rows.isEmpty && originOnly.isEmpty }
}

/// One local clone: its header, then its branches or what went wrong reading it.
struct GardenRepoCard: View {
    @Environment(AppState.self) private var app
    let repo: GardenRepo
    let entry: GardenStore.Entry
    let filters: GardenFilters
    @Binding var picks: Set<GardenPick>
    let onPrune: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider().opacity(0.6)
            content
                .padding(entry.problem == nil && entry.repo != nil ? 0 : 14)
        }
        .card()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.problem == nil ? "folder.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(entry.problem == nil ? Theme.green : Theme.orange)
            VStack(alignment: .leading, spacing: 1) {
                Button { app.openRepo(repo.nameWithOwner) } label: {
                    Text(repo.nameWithOwner).font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Ouvrir le repo")
                Text(repo.path.abbreviatedPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if entry.isLoading { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer()
            if let gitRepo = entry.repo {
                BaseBranchesButton(
                    repo: gitRepo,
                    effective: entry.baseBranches,
                    override: Binding(
                        get: { app.garden.baseBranchOverrides[repo.path.path] },
                        set: { app.garden.setBaseBranches($0, for: repo.path) }
                    )
                )
                VerdictCounts(reports: Array(entry.reports.values))
            }
            Menu {
                LocalOpenButtons(path: repo.path.path)
                Divider()
                Button("Ouvrir le repo") { app.openRepo(repo.nameWithOwner) }
                Button("Réanalyser") { Task { await app.garden.analyze([repo.path]) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.problem {
        case .missing:
            HStack {
                Label("Dossier introuvable : le clone a été déplacé ou supprimé.", systemImage: "questionmark.folder")
                    .foregroundStyle(Theme.orange)
                Spacer()
                Button("Gérer les repos…") { app.isManageReposOpen = true }
            }
        case let .failed(message):
            HStack(alignment: .top) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red).textSelection(.enabled)
                Spacer()
                Button("Réessayer") { Task { await app.garden.analyze([repo.path]) } }
            }
        case nil:
            if let gitRepo = entry.repo {
                BranchTable(repo: gitRepo, reports: entry.reports, filters: filters, picks: $picks, onPrune: onPrune)
            } else {
                ProgressView("Analyse…").controlSize(.small).frame(maxWidth: .infinity)
            }
        }
    }
}

private struct BranchRow: Identifiable {
    let branch: Repo.Branch
    let report: Report?
    let worktree: Repo.Worktree?
    var id: String { branch.name }
    /// Blocked rows can never be selected, and a row is not selectable before its verdict is known.
    var isSelectable: Bool { report.map { $0.verdict != .blocked } ?? false }
}

private struct BranchTable: View {
    @Environment(AppState.self) private var app
    let repo: Repo
    let reports: [String: Report]
    let filters: GardenFilters
    @Binding var picks: Set<GardenPick>
    let onPrune: () -> Void

    var body: some View {
        let visible = VisibleBranches(repo: repo, reports: reports, filters: filters)
        let rows = visible.rows.map { branch in
            BranchRow(branch: branch, report: reports[branch.name], worktree: repo.worktrees.first { $0.branch == branch.name })
        }
        if visible.isEmpty {
            Label {
                Text(filters.isActive ? "Aucune branche ne correspond aux filtres." : "Rien à tailler ici.")
            } icon: {
                Image(systemName: "leaf.fill").foregroundStyle(Theme.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
        } else {
            if !rows.isEmpty { table(rows) }
            if !visible.originOnly.isEmpty {
                if !rows.isEmpty { Divider().opacity(0.6) }
                originOnlyList(visible.originOnly).padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    private func table(_ rows: [BranchRow]) -> some View {
        Table(rows, selection: selection) {
            TableColumn("") { row in
                if row.isSelectable {
                    Toggle("", isOn: pickBinding(row.id)).toggleStyle(.checkbox).labelsHidden()
                }
            }
            .width(24)
            TableColumn("Verdict") { row in
                if let report = row.report {
                    HStack(spacing: 6) {
                        VerdictTag(verdict: report.verdict, reason: report.blockReasonText)
                        if let reason = report.blockReasonText {
                            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(reason)
                        }
                    }
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .width(min: 84, ideal: 110, max: 320)
            TableColumn("Branche") { Text($0.branch.name).font(Theme.mono).help($0.branch.name) }
                .width(min: 120, ideal: 190)
            TableColumn("Emplacement") { LocationLabel(location: $0.branch.location) }
                .width(min: 80, ideal: 105)
            TableColumn("Dernier commit") {
                Text($0.branch.lastCommitDate.shortAgo).foregroundStyle(.secondary)
                    .help($0.branch.lastCommitDate.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 50, ideal: 70)
            TableColumn("Mergée dans") {
                let merged = $0.report?.mergedInto.joined(separator: ", ") ?? ""
                Text(merged).font(Theme.mono).lineLimit(1).help(merged)
            }
            .width(min: 50, ideal: 70)
            TableColumn("PR") { row in
                if let pr = row.report?.pullRequest { prButton(pr) }
            }
            .width(min: 40, ideal: 90)
            TableColumn("Worktree") {
                WorktreeCell(worktree: $0.worktree, conductor: $0.report?.conductor, t3: $0.report?.t3)
            }
                .width(min: 80, ideal: 170)
        }
        .contextMenu(forSelectionType: String.self) { names in
            contextMenu(for: names.compactMap { name in rows.first { $0.id == name } })
        }
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(rows.count + 1) * 28 + 6)
    }

    /// Opens the PR inside the app; GitHub only when its URL can't be read.
    private func prButton(_ pr: BranchAnalyzer.PullRequest) -> some View {
        Button {
            if let ref = pr.ref { app.open(ref) } else { NSWorkspace.shared.open(pr.url) }
        } label: {
            HStack(spacing: 4) {
                Text("#\(pr.number)").foregroundStyle(pr.stateColor)
                Text(pr.stateLabel).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(pr.url.absoluteString)
    }

    @ViewBuilder
    private func contextMenu(for rows: [BranchRow]) -> some View {
        if let row = rows.first, rows.count == 1 {
            Button("Copier le nom de la branche") { Pasteboard.copy(row.branch.name) }
            if let pr = row.report?.pullRequest {
                if let ref = pr.ref { Button("Ouvrir la PR #\(pr.number)") { app.open(ref) } }
                Button("Ouvrir la PR #\(pr.number) sur GitHub") { NSWorkspace.shared.open(pr.url) }
            }
            if let worktree = row.worktree {
                Divider()
                LocalOpenButtons(path: worktree.path.path)
            }
        }
        let prunable = rows.filter(\.isSelectable)
        if !prunable.isEmpty {
            Divider()
            let allPicked = prunable.allSatisfy { picks.contains(GardenPick(repo: repo.id, branch: $0.id)) }
            Button(allPicked ? "Retirer de la sélection" : "Sélectionner pour la taille") {
                for row in prunable {
                    let pick = GardenPick(repo: repo.id, branch: row.id)
                    if allPicked { picks.remove(pick) } else { picks.insert(pick) }
                }
            }
            Button("Supprimer…", role: .destructive) {
                picks = Set(prunable.map { GardenPick(repo: repo.id, branch: $0.id) })
                onPrune()
            }
        }
    }

    private func originOnlyList(_ names: [String]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Toggle(isOn: pickBinding(name)) {
                        HStack {
                            if let report = reports[name] {
                                VerdictTag(verdict: report.verdict, reason: report.blockReasonText)
                                if let reason = report.blockReasonText { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(name).font(Theme.mono)
                            if let merged = reports[name]?.mergedInto, !merged.isEmpty {
                                Text("mergée dans \(merged.joined(separator: ", "))").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(reports[name].map { $0.verdict == .blocked } ?? true)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("\(names.count) uniquement sur origin", systemImage: "icloud").foregroundStyle(.secondary)
        }
    }

    /// Blocked rows and rows still being analyzed can never be selected.
    private var selection: Binding<Set<String>> {
        Binding(
            get: { Set(picks.filter { $0.repo == repo.id }.map(\.branch)) },
            set: { names in
                picks = picks.filter { $0.repo != repo.id }
                    .union(names.filter { reports[$0].map { $0.verdict != .blocked } ?? false }.map { GardenPick(repo: repo.id, branch: $0) })
            }
        )
    }

    private func pickBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { picks.contains(GardenPick(repo: repo.id, branch: name)) },
            set: { isOn in
                let pick = GardenPick(repo: repo.id, branch: name)
                if isOn { picks.insert(pick) } else { picks.remove(pick) }
            }
        )
    }
}

private struct WorktreeCell: View {
    let worktree: Repo.Worktree?
    let conductor: BranchAnalyzer.ConductorState?
    let t3: BranchAnalyzer.T3Thread?

    var body: some View {
        HStack(spacing: 4) {
            // A Conductor Workspace folder is named after a city, a T3 Code one after an id: the badge says more.
            if let t3 {
                GardenTag(text: t3.isActive ? "T3 actif" : "T3 archivé", symbol: "bubble.left.and.text.bubble.right",
                          color: t3.isActive ? Theme.blue : Theme.gray)
                Text(t3.title ?? worktree?.path.lastPathComponent ?? "")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help([t3.title, worktree?.path.path, t3.title == nil ? "Base T3 Code illisible : worktree protégé par prudence." : nil]
                        .compactMap { $0 }.joined(separator: "\n"))
            } else if let conductor {
                GardenTag(text: conductor == .active ? "Conductor actif" : "Conductor archivé", color: Theme.purple)
                    .help(worktree?.path.path ?? "")
            } else if let worktree {
                Label(worktree.path.lastPathComponent, systemImage: "folder").lineLimit(1).help(worktree.path.path)
            }
            if let dirty = worktree?.dirtyFileCount, dirty > 0 {
                GardenTag(text: "\(dirty) modifiés", symbol: "pencil", color: Theme.orange)
            }
            if conductor == .active {
                Button("Ouvrir", action: openConductor).buttonStyle(.link).help("Ouvrir dans Conductor")
            }
        }
    }

    private func openConductor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.conductor.app") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Shows the Base Branches and edits them by ticking the repo's real branches.
private struct BaseBranchesButton: View {
    let repo: Repo
    let effective: [String]
    @Binding var override: [String]?
    @State private var isEditing = false

    private var checked: [String] { override ?? effective }

    private var candidates: [String] {
        let names = Set(repo.branches.map(\.name) + repo.originOnlyBranches)
        return checked.filter(names.contains)
            + names.subtracting(checked).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        Button { isEditing = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(checked.isEmpty ? "Aucune base" : checked.joined(separator: ", ")).font(Theme.monoSmall)
                if override == nil { Text("auto").foregroundStyle(.secondary) }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Branches de base : modifier")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) { editor }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Branches de base").font(.headline)
            Text("Une branche mergée dans l'une d'elles est sûre. Les branches de base ne sont jamais proposées à la suppression.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates, id: \.self) { name in
                        Toggle(name, isOn: isChecked(name))
                            .toggleStyle(.checkbox)
                            .font(Theme.mono)
                            // At least one Base Branch: an empty override would silently mean auto-detect.
                            .disabled(checked == [name])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            Divider()
            HStack {
                Text(override == nil ? "Détection automatique" : "Choix manuel").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revenir à l'auto") { override = nil }.disabled(override == nil)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func isChecked(_ name: String) -> Binding<Bool> {
        Binding(
            get: { checked.contains(name) },
            set: { isOn in
                let names = isOn ? checked + [name] : checked.filter { $0 != name }
                override = candidates.filter(names.contains)
            }
        )
    }
}
