import SwiftUI

/// ⌘K: jump to a pinned repo, a PR from the global lists, or a section.
struct CommandPalette: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = 0

    private struct Item: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var symbol: String
        var action: () -> Void
    }

    var body: some View {
        let results = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                KeySearchField(text: $query, placeholder: "Repo, PR, numéro…", fontSize: 16) { step in
                    selected = min(max(selected + step, 0), max(0, results.count - 1))
                } onSubmit: {
                    activate(results)
                } onCancel: {
                    dismiss()
                }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            Button {
                                selected = index
                                activate(results)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).lineLimit(1)
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(index == selected ? Theme.blue.opacity(0.18) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if results.isEmpty {
                            Text("Aucun résultat").foregroundStyle(.secondary).padding(20)
                        }
                    }
                }
                .onChange(of: selected) { _, index in
                    // Rows are identified by item only: an extra `.id(index)` kept showing stale rows after filtering.
                    let results = items
                    if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                }
            }
        }
        .frame(width: 560, height: 420)
        .background(Theme.panel)
        .dismissOnOutsideClick(dismiss)
        .onChange(of: query) { selected = 0 }
    }

    private var items: [Item] {
        var all: [Item] = [
            Item(id: "home", title: "Home", subtitle: "Vue d'ensemble", symbol: "house") { app.selection = .home },
            Item(id: "inbox", title: "Inbox", subtitle: "Notifications", symbol: "tray") { app.selection = .inbox },
            Item(id: "reviews", title: "Review requests", subtitle: "PRs qui attendent ta review", symbol: "eye") { app.selection = .reviewRequests },
            Item(id: "mine", title: "Mes pull requests", subtitle: "PRs ouvertes par toi", symbol: "arrow.triangle.pull") { app.selection = .pullRequests },
            Item(id: "new-pr", title: "Nouvelle pull request…", subtitle: "⌘N", symbol: "plus.square") { app.startNewPullRequest() },
            Item(id: "manage", title: "Gérer les repos…", subtitle: "Épingler / retirer", symbol: "plus.circle") { app.isManageReposOpen = true },
        ]
        all += app.store.ordered.map { repo in
            Item(id: "repo-" + repo.nameWithOwner, title: repo.nameWithOwner, subtitle: repo.localPath ?? "Repo épinglé", symbol: "folder") {
                app.selection = .repo(repo.nameWithOwner)
            }
        }
        var seen = Set<String>()
        for pr in app.reviewRequests + app.myPRs where seen.insert(pr.id).inserted {
            all.append(Item(id: pr.id, title: pr.title, subtitle: "\(pr.repository.nameWithOwner) #\(pr.number) · \(pr.author?.login ?? "")",
                            symbol: "arrow.triangle.pull") {
                app.selection = .pullRequests
                app.open(pr.ref)
            })
        }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let terms = q.split(separator: " ")
        return all.filter { item in
            let haystack = (item.title + " " + item.subtitle).lowercased()
            return terms.allSatisfy { haystack.contains($0) || haystack.contains("#" + $0) }
        }
    }

    private func activate(_ results: [Item]) {
        guard results.indices.contains(selected) else { return }
        dismiss()
        results[selected].action()
    }
}
