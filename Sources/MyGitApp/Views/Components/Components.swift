import AppKit
import MarkdownUI
import SwiftUI

// MARK: - Avatars

/// In-memory avatar cache with request de-duplication; AsyncImage refetches on every appearance,
/// which makes long lists flicker.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var images: [URL: NSImage] = [:]
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        let task = inFlight[url] ?? Task<Data?, Never> {
            try? await URLSession.shared.data(from: url).0
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        if let image = images[url] { return image }
        guard let data, let image = NSImage(data: data) else { return nil }
        images[url] = image
        return image
    }
}

struct Avatar: View {
    var url: URL?
    var size: CGFloat = 20
    var square = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Theme.fill
            }
        }
        .frame(width: size, height: size)
        .clipShape(square ? AnyShape(RoundedRectangle(cornerRadius: size * 0.22)) : AnyShape(Circle()))
        .task(id: url) {
            guard let url = sizedURL else { return }
            image = await ImageCache.shared.image(for: url)
        }
    }

    private var sizedURL: URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        guard components.host?.contains("avatars.githubusercontent.com") == true else { return url }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: "\(Int(size * 2))")]
        return components.url
    }
}

// MARK: - Small pieces

struct Badge: View {
    var text: String
    var color: Color = Theme.gray
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Theme.onAccent : color)
            .background(filled ? color : color.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(filled ? 0 : 0.3), lineWidth: 0.5))
            .lineLimit(1)
            .fixedSize()
    }
}

struct CIDot: View {
    var status: CIStatus
    var body: some View {
        switch status {
        case .none: EmptyView()
        case .success: Image(systemName: "checkmark.circle").foregroundStyle(Theme.green).help("CI OK")
        case .failure: Image(systemName: "xmark.circle").foregroundStyle(Theme.red).help("CI en échec")
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(Theme.yellow).help("CI en cours")
        case .neutral: Image(systemName: "minus.circle").foregroundStyle(Theme.gray)
        }
    }
}

struct PRStateIcon: View {
    var state: String
    var isDraft: Bool

    var body: some View {
        Image(systemName: symbol).foregroundStyle(color)
    }

    private var symbol: String {
        switch state {
        case "MERGED": "arrow.triangle.merge"
        case "CLOSED": "xmark.circle"
        default: "arrow.triangle.pull"
        }
    }

    private var color: Color {
        if isDraft && state == "OPEN" { return Theme.gray }
        switch state {
        case "MERGED": return Theme.purple
        case "CLOSED": return Theme.red
        default: return Theme.green
        }
    }
}

struct ReviewDecisionBadge: View {
    var decision: String?
    var body: some View {
        switch decision {
        case "APPROVED": Badge(text: "Approved", color: Theme.green)
        case "CHANGES_REQUESTED": Badge(text: "Changes requested", color: Theme.red)
        case "REVIEW_REQUIRED": Badge(text: "Review required", color: Theme.gray)
        default: EmptyView()
        }
    }
}

struct DiffStat: View {
    var additions: Int
    var deletions: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Theme.green)
            Text("−\(deletions)").foregroundStyle(Theme.red)
        }
        .font(Theme.monoSmall)
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    var count: Int?
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            if let count { Text("\(count)").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            if let detail { Text(detail).font(Theme.monoSmall).foregroundStyle(.secondary) }
            Spacer()
            trailing.font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, detail: String? = nil) {
        self.init(title: title, count: count, detail: detail) { EmptyView() }
    }
}

struct ExternalLink: View {
    var title: String
    var url: URL
    var body: some View {
        Link(destination: url) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct EmptyStateText: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ErrorBanner: View {
    var message: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.yellow)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.yellow.opacity(0.25)))
    }
}

extension View {
    /// Bordered panel used for every content block.
    func card(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}

/// Row with hover highlight, used for clickable list rows.
struct HoverRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .contentShape(Rectangle())
                .background(hovering ? Theme.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Tab used by the repo and PR screens; sized like a regular macOS control.
struct TabPill: View {
    var title: String
    var count: Int?
    var isSelected: Bool
    var highlight: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(highlight?.opacity(0.2) ?? Theme.fill, in: Capsule())
                        .foregroundStyle(highlight ?? .secondary)
                }
            }
            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(isSelected ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Markdown

struct MarkdownBody: View {
    var markdown: String

    var body: some View {
        let segments = MarkdownPreprocessor.segments(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let text):
                    Markdown(text).markdownTheme(.app)
                case .details(let summary, let body):
                    DetailsBlock(summary: summary, markdown: body)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailsBlock: View {
    var summary: String
    var markdown: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Markdown(markdown).markdownTheme(.app).padding(.top, 4)
        } label: {
            Text(summary).font(.callout).foregroundStyle(.secondary)
                .onTapGesture { expanded.toggle() }
        }
    }
}

// MARK: - Composer

/// Multi-line input; ⌘↩ submits. `onSubmit` returns true when the text should be cleared.
struct Composer: View {
    var placeholder: String
    var submitLabel: String
    var onCancel: (() -> Void)?
    var onSubmit: (String) async -> Bool
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 64, maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? Theme.blue.opacity(0.6) : Theme.border))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    submit()
                    return .handled
                }
            HStack(spacing: 8) {
                Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if let onCancel { Button("Annuler", action: onCancel) }
                if sending { ProgressView().controlSize(.small) }
                Button(submitLabel, action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
    }

    private func submit() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        Task {
            if await onSubmit(body) { text = "" }
            sending = false
        }
    }
}

// MARK: - PR row

struct PRRowView: View {
    @Environment(AppState.self) private var app
    var pr: PRSummary
    var showRepo = false

    var body: some View {
        HoverRow(action: { app.open(pr.ref) }) {
            HStack(spacing: 10) {
                PRStateIcon(state: pr.state, isDraft: pr.isDraft)
                    .font(.system(size: 13))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("#\(pr.number)").font(Theme.monoSmall)
                        if showRepo { Text("· \(pr.repository.nameWithOwner)") }
                        Text("· \(pr.author?.login ?? "ghost")")
                        Text("· \(pr.updatedAt.shortAgo)")
                        if pr.isDraft { Badge(text: "Draft") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if pr.unresolvedCount > 0 {
                    Label("\(pr.unresolvedCount)", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                        .help("\(pr.unresolvedCount) thread(s) non résolu(s)")
                }
                ReviewDecisionBadge(decision: pr.reviewDecision)
                CIDot(status: pr.ci).font(.system(size: 12))
                DiffStat(additions: pr.additions, deletions: pr.deletions)
                    .frame(minWidth: 70, alignment: .trailing)
                Avatar(url: pr.author?.avatarUrl, size: 18)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .contextMenu {
            Button("Ouvrir sur GitHub") { NSWorkspace.shared.open(pr.url) }
            Button("Copier l'URL") { Pasteboard.copy(pr.url.absoluteString) }
            Button("Copier la branche") { Pasteboard.copy(pr.headRefName) }
        }
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Text briefly replaced by "Copié" after an action.
/// Open / closed switch shared by the PR lists. Closed includes merged.
struct PRStatePicker: View {
    @Binding var showClosed: Bool
    var body: some View {
        Picker("", selection: $showClosed) {
            Text("Ouvertes").tag(false)
            Text("Fermées").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
    }
}

/// Last row of a paginated PR list.
struct LoadMoreRow: View {
    var pager: PRPager

    var body: some View {
        if let page = pager.page, pager.hasMore {
            HStack(spacing: 8) {
                Button("Charger plus") { pager.loadMore() }
                    .buttonStyle(.link)
                    .disabled(pager.loadingMore)
                if pager.loadingMore { ProgressView().controlSize(.mini) }
                Text("\(page.nodes.count) sur \(page.totalCount)").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

struct CopyButton: View {
    var label: String
    var systemImage: String = "doc.on.doc"
    var value: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(value())
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copié" : label, systemImage: copied ? "checkmark" : systemImage)
        }
    }
}

// MARK: - Sheets

extension View {
    /// Closes a sheet when the window behind it is clicked, like a popover. Clicks in the sheet itself, or in a
    /// popover opened from it, don't count.
    func dismissOnOutsideClick(_ dismiss: DismissAction) -> some View {
        modifier(OutsideClickDismiss(dismiss: dismiss))
    }
}

private struct OutsideClickDismiss: ViewModifier {
    var dismiss: DismissAction
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                    // The window behind a sheet is the one that has it attached.
                    guard event.window?.attachedSheet != nil else { return event }
                    dismiss()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
