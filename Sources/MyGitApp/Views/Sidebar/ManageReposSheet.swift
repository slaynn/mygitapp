import AppKit
import SwiftUI

struct ManageReposSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Repos de la sidebar").font(.headline)
                Spacer()
                Picker("", selection: $tab) {
                    Text("GitHub").tag(0)
                    Text("Dossiers locaux").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            .padding(16)
            Divider()
            if tab == 0 { GitHubRepoPicker() } else { LocalFolderPicker() }
            Divider()
            HStack {
                Text("\(app.store.pinned.count) repo(s) épinglé(s)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
        .background(Theme.panel)
        .dismissOnOutsideClick(dismiss)
    }
}

private struct GitHubRepoPicker: View {
    @Environment(AppState.self) private var app
    @State private var repos = Loader<[RepoListItem]>()
    @State private var query = ""
    @State private var showArchived = false
    @State private var manualError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtrer, ou saisir owner/repo pour un repo externe", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(addManual)
                if repos.isLoading { ProgressView().controlSize(.small) }
                Toggle("Archivés", isOn: $showArchived).toggleStyle(.checkbox).font(.callout)
            }
            .padding(12)
            if let manualError { ErrorBanner(message: manualError).padding(.horizontal, 12) }
            if let error = repos.error, repos.value == nil { ErrorBanner(message: error).padding(12) }
            List {
                if looksLikeRepo, !filtered.contains(where: { $0.nameWithOwner.lowercased() == query.lowercased() }) {
                    Button { addManual() } label: {
                        Label("Épingler \(query)", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(filtered) { repo in
                    RepoPickerRow(repo: repo, pinned: app.isPinned(repo.nameWithOwner)) {
                        if app.isPinned(repo.nameWithOwner) {
                            app.store.remove(repo.nameWithOwner)
                        } else {
                            app.pinRepo(repo.nameWithOwner)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .task {
            guard let client = app.client else { return }
            await repos.load("viewer-repositories") { try await client.viewerRepositories() }
        }
    }

    private var filtered: [RepoListItem] {
        let all = repos.value ?? []
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return all.filter { (showArchived || !$0.isArchived) && (q.isEmpty || $0.nameWithOwner.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false)) }
    }

    private var looksLikeRepo: Bool {
        let parts = query.trimmingCharacters(in: .whitespaces).split(separator: "/")
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !query.contains(" ")
    }

    private func addManual() {
        guard looksLikeRepo, let client = app.client else { return }
        let name = query.trimmingCharacters(in: .whitespaces)
        manualError = nil
        Task {
            do {
                let summary = try await client.repoSummaries([name])
                guard let found = summary.values.first else { throw GitHubError.notFound }
                app.pinRepo(found.nameWithOwner)
                query = ""
            } catch {
                manualError = "\(name) : \(error.localizedDescription)"
            }
        }
    }
}

private struct RepoPickerRow: View {
    var repo: RepoListItem
    var pinned: Bool
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { pinned }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Avatar(url: repo.owner.avatarUrl, size: 20, square: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.nameWithOwner).font(.system(size: 13))
                    if repo.isPrivate { Badge(text: "Private") }
                    if repo.isArchived { Badge(text: "Archived", color: Theme.yellow) }
                    if repo.isFork { Badge(text: "Fork") }
                }
                if let description = repo.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let pushed = repo.pushedAt {
                Text(pushed.shortAgo).font(.caption).foregroundStyle(.tertiary)
            }
            if repo.stargazerCount > 0 {
                Label("\(repo.stargazerCount)", systemImage: "star").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .padding(.vertical, 2)
    }
}

private struct LocalFolderPicker: View {
    @Environment(AppState.self) private var app
    @State private var scanned: [LocalRepoInfo] = []
    @State private var scanning = false
    @State private var scannedRoot: String?
    @State private var message: String?

    private var localPinned: [PinnedRepo] { app.store.pinned.filter { $0.localPath != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { addFolder() } label: { Label("Ajouter un dossier…", systemImage: "folder.badge.plus") }
                Button { scanFolder() } label: { Label("Scanner un dossier parent…", systemImage: "magnifyingglass") }
                if scanning { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(12)
            if let message { ErrorBanner(message: message).padding(.horizontal, 12).padding(.bottom, 8) }
            List {
                if !localPinned.isEmpty {
                    Section("Dossiers épinglés") {
                        ForEach(localPinned) { repo in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(Theme.blue)
                                VStack(alignment: .leading) {
                                    Text(repo.nameWithOwner)
                                    Text(repo.localPath ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                                Spacer()
                                Button("Retirer") { app.store.remove(repo.nameWithOwner) }
                            }
                        }
                    }
                }
                if let scannedRoot {
                    Section("Clones trouvés dans \((scannedRoot as NSString).abbreviatingWithTildeInPath)") {
                        if scanned.isEmpty { Text("Aucun dépôt git trouvé.").foregroundStyle(.secondary) }
                        ForEach(scanned) { info in
                            LocalRepoRow(info: info, pinned: info.nameWithOwner.map(app.isPinned) ?? false) {
                                guard let name = info.nameWithOwner else { return }
                                if app.isPinned(name) { app.store.remove(name) } else { app.pinRepo(name, localPath: info.path) }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func choose(_ prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func addFolder() {
        guard let url = choose("Ajouter") else { return }
        message = nil
        guard let info = LocalRepoResolver.resolve(path: url.path) else {
            message = "Ce dossier n'est pas un dépôt git. Utilise « Scanner un dossier parent » pour un dossier qui en contient plusieurs."
            return
        }
        guard let name = info.nameWithOwner else {
            message = "Aucun remote GitHub trouvé dans \(info.folderName)."
            return
        }
        app.pinRepo(name, localPath: info.path)
    }

    private func scanFolder() {
        guard let url = choose("Scanner") else { return }
        scanning = true
        message = nil
        Task {
            scanned = await Task.detached { LocalRepoResolver.scan(parent: url) }.value
            scannedRoot = url.path
            scanning = false
        }
    }
}

private struct LocalRepoRow: View {
    var info: LocalRepoInfo
    var pinned: Bool
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { pinned }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(info.nameWithOwner == nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.folderName).font(.system(size: 13))
                    if let branch = info.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(info.nameWithOwner ?? "Pas de remote GitHub")
                    .font(.caption)
                    .foregroundStyle(info.nameWithOwner == nil ? Theme.yellow : .secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { if info.nameWithOwner != nil { toggle() } }
        .opacity(info.nameWithOwner == nil ? 0.6 : 1)
    }
}
