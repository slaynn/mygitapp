import AppKit
import SwiftUI

/// One review thread: location, the code it targets, then the whole discussion.
/// Resolved and outdated threads start collapsed.
struct ReviewThreadView: View {
    @Environment(AppState.self) private var app
    var thread: ReviewThread
    var model: PRDetailModel
    /// False when rendered inline in the Files tab, where the code is already visible.
    var showExcerpt = true

    @State private var expanded: Bool?
    @State private var replying = false

    var body: some View {
        let isExpanded = expanded ?? !(thread.isResolved || thread.isOutdated)
        VStack(alignment: .leading, spacing: 0) {
            header(isExpanded)
            if isExpanded {
                if showExcerpt, let hunk = thread.root?.diffHunk, !hunk.isEmpty {
                    Divider()
                    DiffExcerptView(hunk: hunk, span: thread.spanLength)
                }
                ForEach(thread.comments.nodes) { comment in
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        AuthorLine(author: comment.author, action: "", date: comment.createdAt, url: comment.url)
                        MarkdownBody(markdown: comment.body)
                    }
                    .padding(12)
                }
                footer
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(thread.isResolved ? Theme.border : Theme.orange.opacity(0.25)))
        .opacity(thread.isResolved && !isExpanded ? 0.75 : 1)
    }

    private func header(_ isExpanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
            if let priority = thread.priority { PriorityBadge(priority: priority) }
            Text(thread.location)
                .font(Theme.monoSmall)
                .lineLimit(1)
                .truncationMode(.head)
            if thread.isResolved { Badge(text: "Résolu", color: Theme.green) }
            if thread.isOutdated { Badge(text: "Outdated", color: Theme.yellow) }
            if !isExpanded {
                if let title = summaryLine {
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("· \(thread.comments.nodes.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if model.busy.contains(thread.id) { ProgressView().controlSize(.mini) }
            CopyButton(label: "Pour l'agent", systemImage: "sparkles") {
                ReviewTimeline.agentPrompt(for: [thread], pr: model.ref)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copier ce thread pour Codex / Claude")
            if thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve {
                Button(thread.isResolved ? "Rouvrir" : "Résoudre") {
                    let resolving = !thread.isResolved
                    if resolving { expanded = false }
                    Task { await model.setResolved(thread, resolving, app: app) }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { expanded = !isExpanded }
    }

    @ViewBuilder private var footer: some View {
        if thread.viewerCanReply {
            Divider()
            Group {
                if replying {
                    Composer(placeholder: "Répondre…", submitLabel: "Répondre", onCancel: { replying = false }) { text in
                        let ok = await model.reply(to: thread, body: text, app: app)
                        if ok { replying = false }
                        return ok
                    }
                } else {
                    HStack {
                        Button { replying = true } label: {
                            Text("Répondre…")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
        }
    }

    /// First meaningful line of the root comment, for the collapsed header.
    private var summaryLine: String? {
        guard let body = thread.root?.body else { return nil }
        let plain = MarkdownPreprocessor.plainText(body)
        let line = plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = line
            .replacingOccurrences(of: #"\[P\d\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }
}

struct PriorityBadge: View {
    var priority: String
    var body: some View {
        Badge(text: priority, color: color, filled: true)
    }
    private var color: Color {
        switch priority {
        case "P0": Theme.red
        case "P1": Theme.orange
        case "P2": Theme.yellow
        default: Theme.blue
        }
    }
}

// MARK: - Diff rendering

struct DiffExcerptView: View {
    var hunk: String
    var span: Int

    var body: some View {
        let excerpt = DiffParser.excerpt(hunk: hunk, span: span)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(excerpt.lines) { line in
                DiffLineRow(line: line, highlighted: excerpt.highlighted.contains(line.id))
            }
        }
        .padding(.vertical, 4)
        .background(Theme.background.opacity(0.6))
    }
}

struct DiffLineRow: View {
    var line: DiffLine
    var highlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if line.kind == .hunkHeader {
                Text(line.text)
                    .foregroundStyle(Theme.blue.opacity(0.8))
                    .padding(.leading, 10)
                    .padding(.vertical, 3)
                Spacer(minLength: 0)
            } else {
                Text(line.oldLine.map(String.init) ?? "")
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                Text(line.newLine.map(String.init) ?? "")
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                Text(marker)
                    .frame(width: 18)
                    .foregroundStyle(markerColor)
                Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.mono)
        .padding(.vertical, 0.5)
        .background(background)
        .overlay(alignment: .leading) {
            if highlighted { Rectangle().fill(Theme.orange).frame(width: 2) }
        }
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private var markerColor: Color {
        line.kind == .addition ? Theme.green : line.kind == .deletion ? Theme.red : .secondary
    }

    private var background: Color {
        switch line.kind {
        case .addition: Theme.green.opacity(highlighted ? 0.22 : 0.12)
        case .deletion: Theme.red.opacity(highlighted ? 0.22 : 0.12)
        case .hunkHeader: Theme.blue.opacity(0.07)
        default: highlighted ? Theme.orange.opacity(0.1) : .clear
        }
    }
}
