import SwiftUI

/// ⌘N: pick a branch, check what it brings, adjust the prefilled title and description, create.
struct NewPullRequestSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: NewPRRequest

    @State private var repo: String
    @State private var context: NewPRContext?
    @State private var loadError: String?
    @State private var base = ""
    @State private var head = ""
    /// Next guesses for `head` while it is still auto-picked: tried in turn when a guess brings no commit.
    @State private var headFallbacks: [String]?
    @State private var comparison: BranchComparison?
    @State private var comparing = false
    @State private var compareError: String?

    @State private var title = ""
    @State private var text = ""
    /// Last prefilled values: a field is only refilled while the user hasn't edited it.
    @State private var autoTitle = ""
    @State private var autoText = ""
    @AppStorage("newPRDraft") private var draft = false
    @State private var preview = false
    @State private var showCommits = false

    @State private var local: LocalState?
    @State private var pushing = false
    @State private var creating = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    /// The pinned clone's checked-out branch, when it isn't fully on GitHub yet.
    private struct LocalState: Equatable {
        var path: String
        var branch: String
        var isOnGitHub: Bool
        var unpushed: Int?
    }

    private struct CompareKey: Hashable { var repo: String; var base: String; var head: String }

    init(request: NewPRRequest) {
        self.request = request
        _repo = State(initialValue: request.repo ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let loadError { ErrorBanner(message: loadError) }
                    if context == nil && loadError == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    } else if context != nil {
                        branchRow
                        localBanner
                        statusBanner
                        form
                        if let error { ErrorBanner(message: error) }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 660)
        .background(Theme.panel)
        .task(id: repo) { await loadContext() }
        .task(id: CompareKey(repo: repo, base: base, head: head)) { await compare() }
    }

    // MARK: Header

    private var repos: [String] {
        var names = app.store.ordered.map(\.nameWithOwner)
        if !repo.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) { names.insert(repo, at: 0) }
        return names
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.pull").foregroundStyle(Theme.green)
            Text("Nouvelle pull request").font(.headline)
            Spacer()
            if repos.count > 1 {
                Picker("Repo", selection: $repo) {
                    ForEach(repos, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text(repo).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Branches

    private var branchRow: some View {
        let branches = context?.branches ?? []
        let isComplete = context?.isComplete ?? true
        return HStack(spacing: 8) {
            BranchField(label: "base", selection: base, branches: branches, isComplete: isComplete, search: searchBranches) { branch in
                adopt(branch)
                base = branch.name
            }
            Image(systemName: "arrow.left").foregroundStyle(.secondary)
            BranchField(label: "compare", selection: head, branches: branches.filter { $0.name != base }, isComplete: isComplete,
                        search: searchBranches) { branch in
                adopt(branch)
                head = branch.name
                headFallbacks = nil
            }
            ProgressView().controlSize(.small).opacity(comparing ? 1 : 0)
        }
    }

    private func searchBranches(_ query: String) async -> [NewPRContext.Branch] {
        guard let client = app.client else { return [] }
        return (try? await client.newPullRequestContext(repo, branchQuery: query, maxPages: 1).branches) ?? []
    }

    /// A branch found by searching GitHub joins the loaded list, so it can be compared.
    private func adopt(_ branch: NewPRContext.Branch) {
        if context?.branches.contains(where: { $0.name == branch.name }) == false { context?.branches.append(branch) }
    }

    private var selectedBranch: NewPRContext.Branch? { context?.branches.first { $0.name == head } }

    // MARK: Banners

    @ViewBuilder private var localBanner: some View {
        if let local, !local.isOnGitHub || (local.unpushed ?? 0) > 0 {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle").foregroundStyle(Theme.blue)
                Text(local.isOnGitHub
                     ? "\(local.unpushed ?? 0) commit(s) de \(local.branch) ne sont pas encore sur GitHub."
                     : "La branche locale \(local.branch) n'est pas encore sur GitHub.")
                    .font(.callout)
                Spacer()
                if pushing { ProgressView().controlSize(.small) }
                Button(local.isOnGitHub ? "Pousser" : "Pousser la branche") { push(local) }
                    .disabled(pushing)
            }
            .padding(10)
            .background(Theme.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.blue.opacity(0.25)))
        }
    }

    @ViewBuilder private var statusBanner: some View {
        if let pr = selectedBranch?.openPR, let ref = PRRef(nameWithOwner: repo, number: pr) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(Theme.yellow)
                Text("Une pull request est déjà ouverte pour \(head) : #\(pr).").font(.callout)
                Spacer()
                Button("Ouvrir #\(pr)") {
                    dismiss()
                    app.open(ref)
                }
            }
            .padding(10)
            .background(Theme.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.yellow.opacity(0.25)))
        } else if let compareError {
            ErrorBanner(message: compareError)
        } else if let comparison {
            if comparison.ahead_by == 0 {
                Label("\(head) n'a aucun commit de plus que \(base) : rien à proposer.", systemImage: "equal.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                commitsSummary(comparison)
            }
        }
    }

    private func commitsSummary(_ comparison: BranchComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showCommits.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: showCommits ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("\(comparison.ahead_by) commit(s)")
                    if let files = comparison.files { Text("· \(files.count) fichier(s)") }
                    DiffStat(additions: comparison.additions, deletions: comparison.deletions)
                    if comparison.behind_by > 0 {
                        Text("· \(comparison.behind_by) en retard sur \(base)").foregroundStyle(Theme.yellow)
                    }
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if showCommits {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(comparison.commits.reversed(), id: \.sha) { commit in
                        HStack(spacing: 8) {
                            Text(commit.sha.prefix(7)).font(Theme.monoSmall).foregroundStyle(.secondary)
                            Text(commit.subject).font(.callout).lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    // MARK: Title and description

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Titre", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($titleFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(titleFocused ? Theme.blue.opacity(0.6) : Theme.border))
            HStack {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $preview) {
                    Text("Écrire").tag(false)
                    Text("Aperçu").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Group {
                if preview {
                    ScrollView {
                        if text.isEmpty {
                            Text("Rien à prévisualiser.").foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownBody(markdown: text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                } else {
                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Décris le changement (markdown)…").foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .frame(height: 320)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Brouillon", isOn: $draft).toggleStyle(.checkbox)
                .help("Créer la PR en draft : elle ne demande pas encore de review.")
            Spacer()
            Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
            Button("Annuler") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if creating { ProgressView().controlSize(.small) }
            Button(draft ? "Créer le brouillon" : "Créer la pull request", action: create)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var canCreate: Bool {
        guard context != nil, !creating, !head.isEmpty, !base.isEmpty, head != base,
              !title.trimmingCharacters(in: .whitespaces).isEmpty, selectedBranch?.openPR == nil
        else { return false }
        return comparison.map { $0.ahead_by > 0 } ?? false
    }

    // MARK: Actions

    private func loadContext() async {
        guard let client = app.client, !repo.isEmpty else {
            loadError = "Épingle un repo dans la sidebar pour pouvoir y créer une pull request."
            return
        }
        context = nil
        loadError = nil
        comparison = nil
        do {
            let fresh = try await client.newPullRequestContext(repo)
            local = await localState(branches: fresh.branches)
            guard !Task.isCancelled else { return }
            context = fresh
            base = fresh.defaultBranch ?? fresh.branches.first?.name ?? ""
            let guesses = defaultHeads(in: fresh)
            let explicit = (request.head != nil && request.repo == repo) || local.map { $0.branch != fresh.defaultBranch } == true
            head = guesses.first ?? ""
            headFallbacks = explicit ? nil : Array(guesses.dropFirst())
            titleFocused = true
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The branch asked for, else the clone's checked-out branch, else my latest branches from the last two weeks
    /// that never had a PR. Otherwise none: an old branch is rarely the one to propose.
    private func defaultHeads(in context: NewPRContext) -> [String] {
        if let wanted = request.head, request.repo == repo { return [wanted] }
        if let local, local.branch != context.defaultBranch { return [local.branch] }
        let cutoff = Date.now.addingTimeInterval(-14 * 86_400)
        let me = app.viewer?.login
        let candidates = context.branches.filter {
            $0.name != context.defaultBranch && !$0.hasPR && ($0.committedDate ?? .distantPast) > cutoff
        }
        let ordered = candidates.filter { $0.isProbablyMine(me) } + candidates.filter { !$0.isProbablyMine(me) }
        return ordered.prefix(4).map(\.name)
    }

    private func localState(branches: [NewPRContext.Branch]) async -> LocalState? {
        guard let path = app.store.repo(named: repo)?.localPath,
              let info = LocalRepoResolver.resolve(path: path),
              let branch = info.branch else { return nil }
        let onGitHub = branches.contains { $0.name == branch }
        let unpushed = onGitHub ? await LocalGit.unpushedCount(in: path) : nil
        return LocalState(path: path, branch: branch, isOnGitHub: onGitHub, unpushed: unpushed)
    }

    private func compare() async {
        comparison = nil
        compareError = nil
        guard let client = app.client, context != nil, !base.isEmpty, !head.isEmpty, base != head else { return }
        guard context?.branches.contains(where: { $0.name == head }) == true else { return }
        comparing = true
        defer { comparing = false }
        do {
            let result = try await client.compare(repo, base: base, head: head)
            if result.ahead_by == 0, var fallbacks = headFallbacks {
                // An auto-picked branch that brings nothing (already merged): try the next guess, or pick none.
                head = fallbacks.isEmpty ? "" : fallbacks.removeFirst()
                headFallbacks = fallbacks
                return
            }
            comparison = result
            prefill(result)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            compareError = error.localizedDescription
        }
    }

    private func prefill(_ comparison: BranchComparison) {
        let messages = comparison.commits.map(\.commit.message)
        let newTitle = PRDraft.title(branch: head, commitMessages: messages)
        let newText = PRDraft.body(commitMessages: messages, template: context?.template)
        if title == autoTitle { title = newTitle }
        if text == autoText { text = newText }
        autoTitle = newTitle
        autoText = newText
    }

    private func push(_ local: LocalState) {
        pushing = true
        error = nil
        Task {
            do {
                try await LocalGit.push(branch: local.branch, in: local.path)
                let requested = local.branch
                await loadContext()
                head = requested
            } catch {
                self.error = "git push : \(error.localizedDescription)"
            }
            pushing = false
        }
    }

    private func create() {
        guard canCreate, let client = app.client, let context, let ref = PRRef(nameWithOwner: repo, number: 0) else { return }
        creating = true
        error = nil
        Task {
            do {
                let number = try await client.createPullRequest(
                    repositoryId: context.repositoryId, base: base, head: head,
                    title: title.trimmingCharacters(in: .whitespaces), body: text, draft: draft)
                dismiss()
                app.didCreatePullRequest(PRRef(owner: ref.owner, name: ref.name, number: number))
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}
