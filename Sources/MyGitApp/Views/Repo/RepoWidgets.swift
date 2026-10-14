import AppKit
import Charts
import SwiftUI

struct RepoHeader: View {
    var repo: RepoOverview
    var starring: Bool
    var toggleStar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Avatar(url: repo.owner.avatarUrl, size: 52, square: true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(repo.name).font(.system(size: 22, weight: .semibold))
                    Badge(text: repo.isPrivate ? "Private" : "Public")
                    if repo.isArchived { Badge(text: "Archived", color: Theme.yellow) }
                    if repo.isFork { Badge(text: "Fork") }
                }
                if let description = repo.description, !description.isEmpty {
                    Text(description).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    if let language = repo.primaryLanguage {
                        HStack(spacing: 5) {
                            Circle().fill(Color(hexString: language.color) ?? Theme.gray).frame(width: 8, height: 8)
                            Text(language.name)
                        }
                    }
                    if let branch = repo.defaultBranchRef?.name {
                        Label(branch, systemImage: "arrow.triangle.branch").font(Theme.monoSmall)
                    }
                    if let license = repo.licenseInfo {
                        Label(license.spdxId ?? license.name, systemImage: "scale.3d")
                    }
                    Label("Updated \((repo.pushedAt ?? repo.updatedAt).shortAgo) ago", systemImage: "clock")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                CountButton(title: repo.viewerHasStarred ? "Starred" : "Star",
                            systemImage: repo.viewerHasStarred ? "star.fill" : "star",
                            tint: repo.viewerHasStarred ? Theme.orange : nil,
                            count: repo.stargazerCount, action: toggleStar)
                    .disabled(starring)
                CountButton(title: "Fork", systemImage: "tuningfork", count: repo.forkCount) {
                    NSWorkspace.shared.open(repo.url.appendingPathComponent("forks"))
                }
                Menu {
                    Button("Copier l'URL HTTPS") { Pasteboard.copy(repo.cloneURL) }
                    Button("Copier l'URL SSH") { Pasteboard.copy(repo.sshUrl) }
                    Button("Copier « gh repo clone »") { Pasteboard.copy("gh repo clone \(repo.nameWithOwner)") }
                } label: {
                    Label("Clone", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
            .controlSize(.small)
        }
    }
}

private struct CountButton: View {
    var title: String
    var systemImage: String
    var tint: Color?
    var count: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(tint ?? .primary)
                Text(title)
                Text(count.formatted()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Stat cards

struct StatCards: View {
    var repo: RepoOverview
    var stars: [Date]?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(title: "Open pull requests") {
                Text("\(repo.pullRequests.totalCount)").font(.system(size: 24, weight: .medium, design: .monospaced))
            }
            .frame(width: 170)
            Divider()
            cell(title: "CI on \(repo.defaultBranchRef?.name ?? "default"), last 7 commits") {
                CIBar(commits: Array(repo.recentCommits.prefix(7)))
            }
            .frame(width: 230)
            Divider()
            cell(title: "Latest release") {
                if let release = repo.latestRelease {
                    Link(destination: release.url) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(release.tagName).font(.system(size: 20, weight: .medium, design: .monospaced))
                            if let date = release.publishedAt {
                                Text("\(date.shortAgo) ago").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("—").font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 200)
            Divider()
            // Charts report a large minimum width; without minWidth: 0 the whole page overflows.
            StarsSparkline(total: repo.stargazerCount, stars: stars)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 96)
    }

    private func cell<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CIBar: View {
    var commits: [CommitInfo]

    var body: some View {
        let statuses = commits.reversed().map { $0.statusCheckRollup?.ci ?? .none }
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.color(for: status).opacity(status == .none ? 0.35 : 1))
                        .frame(width: 6, height: 14)
                }
            }
            // Merge commits often carry no checks: report the newest commit that has some.
            let latest = commits.lazy.compactMap(\.statusCheckRollup).first?.ci ?? .none
            Text(label(latest)).font(.system(size: 12)).foregroundStyle(Theme.color(for: latest))
        }
    }

    private func label(_ status: CIStatus) -> String {
        switch status {
        case .success: "Passing"
        case .failure: "Failing"
        case .pending: "Running"
        case .neutral: "Neutral"
        case .none: "No CI"
        }
    }
}

struct StarsSparkline: View {
    var total: Int
    var stars: [Date]?

    private struct Point: Identifiable { var day: Date; var count: Int; var id: Date { day } }

    var body: some View {
        let recent = stars ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Stars, last 30 days").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if stars != nil {
                    Text(recent.isEmpty ? "No new stars" : "+\(recent.count) this month")
                        .font(.system(size: 11.5))
                        .foregroundStyle(recent.isEmpty ? .secondary : Theme.orange)
                }
            }
            Chart(points(recent)) { point in
                AreaMark(x: .value("Day", point.day), y: .value("Stars", point.count))
                    .foregroundStyle(LinearGradient(colors: [Theme.orange.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", point.day), y: .value("Stars", point.count))
                    .foregroundStyle(Theme.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    /// Cumulative star count per day over the last 30 days.
    private func points(_ recent: [Date]) -> [Point] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var perDay: [Date: Int] = [:]
        for date in recent { perDay[calendar.startOfDay(for: date), default: 0] += 1 }
        var running = total - recent.count
        return (0...30).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            running += perDay[day] ?? 0
            return Point(day: day, count: running)
        }
    }
}

// MARK: - Commits

struct RecentCommits: View {
    var repo: RepoOverview

    var body: some View {
        SectionHeader(title: "Recent commits", detail: repo.defaultBranchRef?.name) {
            ExternalLink(title: "History", url: repo.url.appendingPathComponent("commits"))
        }
        Divider().opacity(0.5)
        if repo.recentCommits.isEmpty { EmptyStateText(text: "Aucun commit.") }
        ForEach(repo.recentCommits) { commit in
            CommitRow(commit: commit)
            Divider().opacity(0.4)
        }
    }
}

struct CommitRow: View {
    var commit: CommitInfo
    var compact = false

    var body: some View {
        HoverRow(action: { NSWorkspace.shared.open(commit.url) }) {
            HStack(spacing: 10) {
                Group {
                    if let rollup = commit.statusCheckRollup {
                        CIDot(status: rollup.ci)
                    } else {
                        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 14)
                Text(commit.abbreviatedOid).font(Theme.monoSmall).foregroundStyle(.secondary)
                Text(commit.messageHeadline).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 8)
                if !compact {
                    Avatar(url: commit.author?.avatarUrl, size: 16)
                    Text(commit.author?.display ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                Text(commit.committedDate.shortAgo).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, compact ? 5 : 9)
        }
        .contextMenu {
            Button("Copier le SHA") { Pasteboard.copy(commit.oid) }
            Button("Ouvrir sur GitHub") { NSWorkspace.shared.open(commit.url) }
        }
    }
}

// MARK: - About

struct AboutPanel: View {
    var repo: RepoOverview
    var contributors: [Contributor]?
    var localPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("About").font(.system(size: 12.5, weight: .semibold))
                if let homepage = repo.homepageUrl, !homepage.isEmpty,
                   let url = URL(string: homepage.hasPrefix("http") ? homepage : "https://\(homepage)") {
                    Link(destination: url) {
                        Label(url.host() ?? homepage, systemImage: "link")
                    }
                    .foregroundStyle(Theme.blue)
                }
                Link(destination: URL(string: repo.url.absoluteString + "#readme")!) {
                    Label("README", systemImage: "book")
                }
                .foregroundStyle(.secondary)
                let topics = repo.repositoryTopics.nodes.map(\.topic.name)
                if !topics.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(topics, id: \.self) { Badge(text: $0, color: Theme.blue) }
                    }
                }
            }
            .font(.system(size: 12))

            if let localPath {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clone local").font(.system(size: 12.5, weight: .semibold))
                    let info = LocalRepoResolver.resolve(path: localPath)
                    Text((localPath as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                    if let branch = info?.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").font(Theme.monoSmall)
                    }
                    Menu("Ouvrir…") { LocalOpenButtons(path: localPath) }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .fixedSize()
                }
            }

            if !repo.languages.edges.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Languages").font(.system(size: 12.5, weight: .semibold))
                    LanguageBar(languages: repo.languages)
                }
            }

            if let contributors, !contributors.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Text("Contributors").font(.system(size: 12.5, weight: .semibold))
                        Text(contributors.count >= 100 ? "100+" : "\(contributors.count)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: -5) {
                        ForEach(contributors.prefix(8)) { person in
                            Avatar(url: person.avatar_url, size: 22)
                                .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                                .help("\(person.login) · \(person.contributions) commits")
                        }
                        if contributors.count > 8 {
                            Text("+\(contributors.count - 8)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 10)
                        }
                    }
                }
            }
        }
        .padding(18)
    }
}

struct LanguageBar: View {
    var languages: RepoOverview.Languages

    var body: some View {
        let total = max(1, languages.totalSize)
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(languages.edges, id: \.node.name) { edge in
                        Rectangle()
                            .fill(Color(hexString: edge.node.color) ?? Theme.gray)
                            .frame(width: max(2, geo.size.width * CGFloat(edge.size) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            FlowLayout(spacing: 10) {
                ForEach(languages.edges.prefix(6), id: \.node.name) { edge in
                    HStack(spacing: 4) {
                        Circle().fill(Color(hexString: edge.node.color) ?? Theme.gray).frame(width: 7, height: 7)
                        Text(edge.node.name)
                        Text(percent(edge.size, total)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func percent(_ size: Int, _ total: Int) -> String {
        let value = Double(size) / Double(total) * 100
        return value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
}

/// Wrapping horizontal layout for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
