import GitGardenerCore
import SwiftUI

/// Local branches and worktrees of the pinned repos that have a local clone, with a safety verdict each,
/// to prune in bulk what is merged or abandoned.
struct GardenView: View {
    @Environment(AppState.self) private var app
    @State private var filters = GardenFilters(verdict: [SafetyVerdict.safe, .review, .risky, .blocked]
        .first { "\($0)" == DebugHooks.initialVerdict })
    @State private var isPruning = false
    @State private var isLogOpen = false
    @State private var notices: [GardenNotice] = []

    private var garden: GardenStore { app.garden }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Branches locales", subtitle: subtitle) { headerButtons }
                        .padding(.horizontal, -24)
                    if !garden.repos.isEmpty { filterBar }
                    banners
                    content
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            if !garden.picks.isEmpty { actionBar }
        }
        .background(Theme.background)
        .navigationTitle("Branches locales")
        .sheet(isPresented: $isPruning) {
            PruneConfirmationSheet(targets: pruneTargets, baseBranchOverrides: garden.baseBranchOverrides, onFinish: finishPrune)
        }
        .sheet(isPresented: $isLogOpen) { PruneLogSheet() }
    }

    // MARK: Header

    private var subtitle: String {
        let count = garden.repos.count
        return count == 0 ? "Aucun clone local" : "\(count) clone\(count > 1 ? "s" : "") local\(count > 1 ? "aux" : "")"
    }

    private var headerButtons: some View {
        HStack(spacing: 10) {
            AnalysisStatus(garden: garden)
            Button(action: selectSafe) { Label("Sélectionner les sûres", systemImage: "checkmark.circle") }
                .help("Sélectionner toutes les branches sûres affichées")
                .disabled(garden.repos.isEmpty)
            Button { isLogOpen = true } label: { Label("Journal", systemImage: "clock.arrow.circlepath") }
                .help("Journal des suppressions : restaurer une branche")
            Button { Task { await garden.analyzeAll() } } label: { Label("Réanalyser", systemImage: "arrow.clockwise") }
                .disabled(garden.isAnalyzing || garden.repos.isEmpty)
        }
    }

    private var filterBar: some View {
        @Bindable var app = app
        return HStack(spacing: 10) {
            Picker("", selection: $filters.verdict) {
                Text("À tailler").tag(SafetyVerdict?.none)
                ForEach([SafetyVerdict.safe, .review, .risky, .blocked], id: \.self) {
                    Text($0.pluralLabel).tag(SafetyVerdict?.some($0))
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Filtrer par verdict")
            if garden.repos.count > 1 {
                Picker("", selection: $app.gardenFocus) {
                    Text("Tous les repos").tag(URL?.none)
                    ForEach(garden.repos) { Text($0.nameWithOwner).tag(URL?.some($0.path)) }
                }
                .fixedSize()
            }
            Menu {
                Picker("Emplacement", selection: $filters.location) {
                    Text("Tous").tag(GardenFilters.Location?.none)
                    ForEach(GardenFilters.Location.allCases, id: \.self) {
                        Text($0.label).tag(GardenFilters.Location?.some($0))
                    }
                }
                .pickerStyle(.inline)
                Picker("Dernier commit", selection: $filters.minimumAgeInDays) {
                    ForEach(GardenFilters.ages, id: \.self) { days in
                        Text(days == 0 ? "Peu importe" : "Il y a plus de \(days) jours").tag(days)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                let isFiltered = filters.location != nil || filters.minimumAgeInDays > 0
                Label("Filtres", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            .help("Filtrer par emplacement et par âge")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Rechercher une branche", text: $filters.search).textFieldStyle(.plain)
                if !filters.search.isEmpty {
                    Button { filters.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 220)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var banners: some View {
        ForEach(garden.prerequisites, id: \.self) { prerequisite in
            GardenBanner(text: prerequisite.message, isError: prerequisite == .gitMissing)
        }
        ForEach(notices) { notice in
            GardenBanner(text: notice.text, isError: notice.isError) { notices.removeAll { $0.id == notice.id } }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if garden.repos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aucun repo épinglé n'a de clone local.").font(.headline)
                Text("Ajoute le dossier d'un clone (ou d'un worktree) depuis « Gérer les repos » : ses branches et worktrees apparaîtront ici avec un verdict de sécurité, pour supprimer en lot ce qui est mergé ou abandonné.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Gérer les repos…") { app.isManageReposOpen = true }
                    .buttonStyle(.borderedProminent)
            }
            .card(padding: 18)
        } else {
            let repos = visibleRepos
            if repos.isEmpty {
                EmptyStateText(text: "Aucune branche ne correspond aux filtres.").card()
            }
            ForEach(repos) { repo in
                GardenRepoCard(
                    repo: repo,
                    entry: garden.entries[repo.path] ?? GardenStore.Entry(isLoading: true),
                    filters: filters,
                    picks: Binding(get: { garden.picks }, set: { garden.picks = $0 }),
                    onPrune: { isPruning = true }
                )
            }
        }
    }

    /// The focused repo alone, or all of them. With filters on, repos with nothing to show are left out;
    /// repos that failed always stay visible.
    private var visibleRepos: [GardenRepo] {
        let repos = app.gardenFocus.flatMap { garden.repo(at: $0) }.map { [$0] } ?? garden.repos
        guard filters.isActive else { return repos }
        return repos.filter { repo in
            guard let entry = garden.entries[repo.path], let gitRepo = entry.repo, entry.problem == nil else { return true }
            return !VisibleBranches(repo: gitRepo, reports: entry.reports, filters: filters).isEmpty
        }
    }

    private var actionBar: some View {
        let worktrees = pruneTargets.filter { $0.worktreePath != nil }.count
        let count = garden.picks.count
        return HStack(spacing: 12) {
            Image(systemName: "scissors").foregroundStyle(Theme.green)
            Text("\(count) branche\(count > 1 ? "s" : "") sélectionnée\(count > 1 ? "s" : "")")
                .font(.headline)
            if worktrees > 0 {
                Text("dont \(worktrees) avec worktree").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Tout désélectionner") { garden.picks = [] }
            Button(role: .destructive) { isPruning = true } label: {
                Label("Supprimer…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.red)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Actions

    private var pruneTargets: [Pruner.Target] {
        garden.picks.sorted { ($0.repo.path, $0.branch) < ($1.repo.path, $1.branch) }.compactMap { pick in
            guard let entry = garden.entries[pick.repo], let repo = entry.repo,
                  let verdict = entry.reports[pick.branch]?.verdict
            else { return nil }
            // Origin Only must come from the scan, never from a local branch that merely went missing.
            let branch = repo.branches.first { $0.name == pick.branch }
            let isOriginOnly = branch == nil && repo.originOnlyBranches.contains(pick.branch)
            guard branch != nil || isOriginOnly else { return nil }
            return Pruner.Target(
                repoPath: repo.path, branch: pick.branch, worktreePath: branch?.worktreePath,
                keepsBranch: false, isOriginOnly: isOriginOnly, verdict: verdict
            )
        }
    }

    /// Visible local branches only: Origin Only ones would be deleted on origin, which must stay an explicit choice,
    /// and rows hidden by the filters must not be pruned unseen.
    private func selectSafe() {
        for repo in visibleRepos {
            guard let entry = garden.entries[repo.path], let gitRepo = entry.repo else { continue }
            for branch in gitRepo.branches where entry.reports[branch.name]?.verdict == .safe
                && filters.matches(branch, verdict: .safe) {
                garden.picks.insert(GardenPick(repo: repo.path, branch: branch.name))
            }
        }
    }

    private func finishPrune(_ outcomes: [Pruner.Outcome]) {
        garden.picks = []
        for outcome in outcomes {
            if let message = outcome.errorMessage { notify("\(outcome.target.name) : \(message)", isError: true) }
        }
        let failed = outcomes.filter { $0.errorMessage != nil }.count
        if outcomes.count > failed {
            notify("\(outcomes.count - failed) élément\(outcomes.count - failed > 1 ? "s" : "") supprimé\(outcomes.count - failed > 1 ? "s" : ""). Le journal permet de les restaurer pendant 30 jours.")
        }
        Task { await garden.analyze(Array(Set(outcomes.map(\.target.repoPath)))) }
    }

    private func notify(_ text: String, isError: Bool = false) {
        let notice = GardenNotice(text: text, isError: isError)
        notices.append(notice)
        guard !isError else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            notices.removeAll { $0.id == notice.id }
        }
    }
}

private struct AnalysisStatus: View {
    let garden: GardenStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 6) {
                if garden.isAnalyzing {
                    ProgressView().controlSize(.mini)
                    Text("Analyse \(garden.analyzedCount)/\(garden.queuedCount)…")
                } else if let last = garden.lastAnalysis {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.green)
                    Text(Date.now.timeIntervalSince(last) < 60 ? "Analysé à l'instant" : "Analysé il y a \(last.shortAgo)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
