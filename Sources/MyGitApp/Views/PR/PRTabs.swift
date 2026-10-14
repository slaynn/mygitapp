import AppKit
import SwiftUI

/// Every review thread grouped by file: a to-do list for working through a review.
struct ThreadsTab: View {
    var pr: PRDetail
    var model: PRDetailModel
    var hideResolved: Bool

    var body: some View {
        let all = pr.extra.reviewThreads.nodes
        let visible = all.filter { !(hideResolved && $0.isResolved) }
        let unresolved = all.filter { !$0.isResolved }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(unresolved.count) non résolu(s) sur \(all.count)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if !unresolved.isEmpty {
                    CopyButton(label: "Copier les non résolus pour l'agent", systemImage: "sparkles") {
                        ReviewTimeline.agentPrompt(for: unresolved, pr: model.ref)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if all.isEmpty {
                EmptyStateText(text: "Aucun commentaire de review sur le code.").card()
            } else if visible.isEmpty {
                EmptyStateText(text: "Tous les threads sont résolus. 🎉").card()
            }
            ForEach(ReviewTimeline.threadsByFile(visible), id: \.path) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(group.path).font(Theme.mono).textSelection(.enabled)
                        Text("\(group.threads.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(group.threads) { thread in
                        ReviewThreadView(thread: thread, model: model)
                    }
                }
            }
        }
    }
}

// MARK: - Files

struct FilesTab: View {
    var model: PRDetailModel
    var threads: [ReviewThread]
    @State private var collapsed: Set<String> = []
    @State private var expandedByUser: Set<String> = []

    private static let generated = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "composer.lock", "Cargo.lock",
                                    "Gemfile.lock", "Podfile.lock", "bun.lockb", "Package.resolved"]

    var body: some View {
        if let error = model.files.error, model.files.value == nil {
            ErrorBanner(message: error)
        } else if let files = model.files.value {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(files.count) fichier(s)").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Tout replier") { collapsed = Set(files.map(\.filename)); expandedByUser = [] }
                        .buttonStyle(.link).font(.caption)
                    Button("Tout déplier") { collapsed = []; expandedByUser = Set(files.map(\.filename)) }
                        .buttonStyle(.link).font(.caption)
                }
                ForEach(files) { file in
                    FileDiffView(file: file,
                                 threads: threads.filter { $0.path == file.filename },
                                 model: model,
                                 isExpanded: isExpanded(file),
                                 toggle: { toggle(file) })
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        }
    }

    /// Lockfiles and very large diffs start collapsed.
    private func isExpanded(_ file: PRFile) -> Bool {
        if collapsed.contains(file.filename) { return false }
        if expandedByUser.contains(file.filename) { return true }
        let name = (file.filename as NSString).lastPathComponent
        return !Self.generated.contains(name) && file.additions + file.deletions <= 600
    }

    private func toggle(_ file: PRFile) {
        if isExpanded(file) {
            collapsed.insert(file.filename)
            expandedByUser.remove(file.filename)
        } else {
            collapsed.remove(file.filename)
            expandedByUser.insert(file.filename)
        }
    }
}

private struct FileDiffView: View {
    var file: PRFile
    var threads: [ReviewThread]
    var model: PRDetailModel
    var isExpanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                if let patch = file.patch {
                    let lines = DiffParser.parse(patch)
                    let anchored = anchoredThreads(lines)
                    let outdated = threads.filter { thread in !anchored.values.contains { $0.contains { $0.id == thread.id } } }
                    if !outdated.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(outdated) { ReviewThreadView(thread: $0, model: model) }
                        }
                        .padding(10)
                        Divider()
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            DiffLineRow(line: line)
                            if let lineThreads = anchored[line.id] {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(lineThreads) { ReviewThreadView(thread: $0, model: model, showExcerpt: false) }
                                }
                                .padding(10)
                                .background(Theme.background)
                            }
                        }
                    }
                } else {
                    EmptyStateText(text: "Diff non disponible (fichier binaire ou trop volumineux).")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .card()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
            statusIcon
            if let previous = file.previous_filename {
                Text(previous).font(Theme.mono).foregroundStyle(.secondary).strikethrough()
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            }
            Text(file.filename).font(Theme.mono).lineLimit(1).truncationMode(.head)
            if !threads.isEmpty {
                let open = threads.filter { !$0.isResolved }.count
                Label("\(open)/\(threads.count)", systemImage: "bubble.left")
                    .font(.system(size: 11))
                    .foregroundStyle(open > 0 ? Theme.orange : .secondary)
            }
            Spacer()
            DiffStat(additions: file.additions, deletions: file.deletions)
            Button { Pasteboard.copy(file.filename) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copier le chemin")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.raised)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    @ViewBuilder private var statusIcon: some View {
        switch file.status {
        case "added": Image(systemName: "plus.square").foregroundStyle(Theme.green)
        case "removed": Image(systemName: "minus.square").foregroundStyle(Theme.red)
        case "renamed": Image(systemName: "arrow.right.square").foregroundStyle(Theme.blue)
        default: Image(systemName: "square.dashed.inset.filled").foregroundStyle(Theme.yellow)
        }
    }

    /// Diff line id → threads whose (side, line) lands on it.
    private func anchoredThreads(_ lines: [DiffLine]) -> [Int: [ReviewThread]] {
        var result: [Int: [ReviewThread]] = [:]
        for thread in threads {
            guard let target = thread.line else { continue }
            let match = lines.first { line in
                thread.diffSide == "LEFT" ? (line.kind == .deletion || line.kind == .context) && line.oldLine == target
                                          : (line.kind == .addition || line.kind == .context) && line.newLine == target
            }
            if let match { result[match.id, default: []].append(thread) }
        }
        return result
    }
}

// MARK: - Checks

struct ChecksTab: View {
    var checks: [CheckItem]
    var prURL: URL

    var body: some View {
        let sorted = checks.sorted { order($0.status) < order($1.status) }
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Checks", count: checks.count) {
                ExternalLink(title: "Voir sur GitHub", url: prURL.appendingPathComponent("checks"))
            }
            Divider()
            if checks.isEmpty { EmptyStateText(text: "Aucun check sur le dernier commit.") }
            ForEach(sorted) { check in
                HoverRow(action: { if let url = check.url { NSWorkspace.shared.open(url) } }) {
                    HStack(spacing: 10) {
                        CIDot(status: check.status == .none ? .neutral : check.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.name).font(.system(size: 12.5))
                            if let workflow = check.workflow {
                                Text(workflow).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let detail = check.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let duration = durationText(check) {
                            Text(duration).font(Theme.monoSmall).foregroundStyle(.tertiary)
                        }
                        if check.url != nil { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
                Divider().opacity(0.4)
            }
        }
        .card()
    }

    private func durationText(_ check: CheckItem) -> String? {
        guard let start = check.startedAt, let end = check.completedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    private func order(_ status: CIStatus) -> Int {
        switch status {
        case .failure: 0
        case .pending: 1
        case .neutral, .none: 2
        case .success: 3
        }
    }
}
