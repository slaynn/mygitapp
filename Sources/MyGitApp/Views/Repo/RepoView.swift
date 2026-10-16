import AppKit
import SwiftUI

struct RepoView: View {
    @Environment(AppState.self) private var app
    var nameWithOwner: String

    @State private var overview = Loader<RepoOverview>()
    @State private var stars = Loader<[Date]>()
    @State private var contributors = Loader<[Contributor]>()
    @State private var prContext: NewPRContext?
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
                        RecentBranchesBanner(repo: nameWithOwner, context: prContext)
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
        .prefetching(overview.value?.pullRequests.nodes ?? [])
        .task(id: LoadKey(name: nameWithOwner, tick: app.refreshTick)) {
            guard let client = app.client else { return }
            async let o: Void = overview.load("repo-\(nameWithOwner)") { try await client.repoOverview(nameWithOwner) }
            async let b = try? client.newPullRequestContext(nameWithOwner, maxPages: 3)
            _ = await o
            prContext = await b
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
            Button { app.startNewPullRequest(repo: nameWithOwner) } label: {
                Label("Nouvelle PR", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Créer une pull request (⌘N)")
            Link(destination: URL(string: "https://github.com/\(nameWithOwner)")!) {
                Label("Open on GitHub", systemImage: "arrow.up.right")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.topBarHeight)
    }

    private func tabButton(_ title: String, _ value: Tab, count: Int? = nil) -> some View {
        TabPill(title: title, count: count.flatMap { $0 > 0 ? $0 : nil }, isSelected: tab == value, highlight: nil) { tab = value }
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

/// "feat/x had recent pushes": one click to open its pull request, like on GitHub.
private struct RecentBranchesBanner: View {
    @Environment(AppState.self) private var app
    var repo: String
    var context: NewPRContext?

    private var branches: [NewPRContext.Branch] {
        guard let context else { return [] }
        let cutoff = Date.now.addingTimeInterval(-3 * 86_400)
        return context.branches.filter {
            $0.name != context.defaultBranch && !$0.hasPR && $0.isProbablyMine(app.viewer?.login)
                && ($0.committedDate ?? .distantPast) > cutoff
        }
        .prefix(3)
        .map { $0 }
    }

    var body: some View {
        if !branches.isEmpty {
            VStack(spacing: 6) {
                ForEach(branches) { branch in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.yellow)
                        Text(branch.name).font(Theme.mono).fontWeight(.medium)
                        if let date = branch.committedDate {
                            Text("dernier commit il y a \(date.shortAgo)").font(.callout).foregroundStyle(.secondary)
                        }
                        if let headline = branch.headline {
                            Text("· \(headline)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Créer une PR") { app.startNewPullRequest(repo: repo, head: branch.name) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.yellow.opacity(0.25)))
                }
            }
            .padding([.horizontal, .top], 24)
        }
    }
}

private struct RepoPullsTab: View {
    @Environment(AppState.self) private var app
    var repo: RepoOverview
    @State private var showClosed = false
    @State private var onlyMine = false
    @State private var closed = PRPager()

    private struct ClosedKey: Hashable { var name: String; var tick: Int }

    var body: some View {
        let source = showClosed ? closed.page?.nodes ?? [] : repo.pullRequests.nodes
        let prs = source.filter { !onlyMine || $0.author?.login == app.viewer?.login }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PRStatePicker(showClosed: $showClosed)
                Picker("", selection: $onlyMine) {
                    Text("Toutes").tag(false)
                    Text("Les miennes").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                if showClosed && closed.first.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                ExternalLink(title: "All on GitHub",
                             url: repo.url.appendingPathComponent("pulls").appending(queryItems: [
                                 URLQueryItem(name: "q", value: showClosed ? "is:pr is:closed" : "is:pr is:open"),
                             ]))
            }
            .padding(16)
            if showClosed, let error = closed.first.error {
                ErrorBanner(message: error).padding([.horizontal, .bottom], 16)
            }
            VStack(spacing: 0) {
                if prs.isEmpty && !(showClosed && closed.page == nil) {
                    EmptyStateText(text: showClosed ? "Aucune PR fermée." : "Aucune PR ouverte.")
                }
                ForEach(prs) { pr in
                    PRRowView(pr: pr)
                    if pr.id != prs.last?.id { Divider().opacity(0.4) }
                }
                if showClosed { LoadMoreRow(pager: closed) }
            }
            .card()
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .prefetching(showClosed ? prs : [])
        .task(id: showClosed ? ClosedKey(name: repo.nameWithOwner, tick: app.refreshTick) : nil) {
            guard showClosed, let client = app.client else { return }
            let name = repo.nameWithOwner
            await closed.load("closed-prs-\(name)") { try await client.closedPullRequests(name, after: $0) }
        }
    }
}
