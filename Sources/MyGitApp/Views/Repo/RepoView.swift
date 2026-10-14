import AppKit
import SwiftUI

struct RepoView: View {
    @Environment(AppState.self) private var app
    var nameWithOwner: String

    @State private var overview = Loader<RepoOverview>()
    @State private var stars = Loader<[Date]>()
    @State private var contributors = Loader<[Contributor]>()
    @State private var tab = Tab.overview
    @State private var starring = false

    enum Tab: Hashable { case overview, pulls }

    private struct LoadKey: Hashable { var name: String; var tick: Int }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = overview.error {
                        ErrorBanner(message: error).padding([.horizontal, .top], 24)
                    }
                    if let repo = overview.value {
                        switch tab {
                        case .overview: overviewContent(repo)
                        case .pulls: RepoPullsTab(repo: repo)
                        }
                    } else if overview.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(60)
                    }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(nameWithOwner)
        .task(id: LoadKey(name: nameWithOwner, tick: app.refreshTick)) {
            guard let client = app.client else { return }
            await overview.load("repo-\(nameWithOwner)") { try await client.repoOverview(nameWithOwner) }
        }
        .task(id: nameWithOwner) {
            guard let client = app.client else { return }
            async let s: Void = stars.load("stars-\(nameWithOwner)") { try await client.recentStars(nameWithOwner) }
            async let c: Void = contributors.load("contributors-\(nameWithOwner)") { try await client.contributors(nameWithOwner) }
            _ = await (s, c)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                let parts = nameWithOwner.split(separator: "/")
                Avatar(url: overview.value?.owner.avatarUrl, size: 16, square: true)
                Text(parts.first.map(String.init) ?? "").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(parts.last.map(String.init) ?? "").fontWeight(.semibold)
            }
            .font(.system(size: 13))
            HStack(spacing: 2) {
                tabButton("Overview", .overview)
                tabButton("Pull requests", .pulls, count: overview.value?.pullRequests.totalCount)
            }
            Spacer()
            if overview.isLoading { ProgressView().controlSize(.small) }
            Link(destination: URL(string: "https://github.com/\(nameWithOwner)")!) {
                Label("Open on GitHub", systemImage: "arrow.up.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func tabButton(_ title: String, _ value: Tab, count: Int? = nil) -> some View {
        Button {
            tab = value
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if let count, count > 0 { Text("\(count)").foregroundStyle(.secondary) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tab == value ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: Overview

    @ViewBuilder private func overviewContent(_ repo: RepoOverview) -> some View {
        RepoHeader(repo: repo, starring: starring, toggleStar: { toggleStar(repo) })
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        Divider()
        StatCards(repo: repo, stars: stars.value)
        Divider()
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                openPulls(repo)
                Divider()
                RecentCommits(repo: repo)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
            AboutPanel(repo: repo, contributors: contributors.value, localPath: app.store.repo(named: repo.nameWithOwner)?.localPath)
                .frame(width: 290, alignment: .topLeading)
        }
    }

    @ViewBuilder private func openPulls(_ repo: RepoOverview) -> some View {
        SectionHeader(title: "Open pull requests", count: repo.pullRequests.totalCount) {
            ExternalLink(title: "All on GitHub", url: repo.url.appendingPathComponent("pulls"))
        }
        Divider().opacity(0.5)
        if repo.pullRequests.nodes.isEmpty {
            EmptyStateText(text: "No open pull requests.")
        } else {
            ForEach(repo.pullRequests.nodes.prefix(8)) { pr in
                PRRowView(pr: pr)
                Divider().opacity(0.4)
            }
            if repo.pullRequests.totalCount > 8 {
                Button("Voir les \(repo.pullRequests.totalCount) PRs") { tab = .pulls }
                    .buttonStyle(.link)
                    .padding(12)
            }
        }
    }

    private func toggleStar(_ repo: RepoOverview) {
        guard let client = app.client, !starring else { return }
        starring = true
        let wasStarred = repo.viewerHasStarred
        overview.value?.viewerHasStarred.toggle()
        overview.value?.stargazerCount += wasStarred ? -1 : 1
        Task {
            do {
                try await client.mutate(wasStarred ? Queries.removeStar : Queries.addStar, ["id": repo.id])
            } catch {
                overview.value?.viewerHasStarred = wasStarred
                overview.value?.stargazerCount += wasStarred ? 1 : -1
                overview.error = error.localizedDescription
            }
            starring = false
        }
    }
}

private struct RepoPullsTab: View {
    @Environment(AppState.self) private var app
    var repo: RepoOverview
    @State private var onlyMine = false

    var body: some View {
        let prs = repo.pullRequests.nodes.filter { !onlyMine || $0.author?.login == app.viewer?.login }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $onlyMine) {
                    Text("Toutes").tag(false)
                    Text("Les miennes").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
                ExternalLink(title: "All on GitHub", url: repo.url.appendingPathComponent("pulls"))
            }
            .padding(16)
            VStack(spacing: 0) {
                if prs.isEmpty { EmptyStateText(text: "Aucune PR ouverte.") }
                ForEach(prs) { pr in
                    PRRowView(pr: pr)
                    if pr.id != prs.last?.id { Divider().opacity(0.4) }
                }
            }
            .card()
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}
