import AppKit
import SwiftUI

/// Branch selector for repos with many branches: click, type to filter, ↑↓ to move, ↩ to pick.
struct BranchField: View {
    typealias Branch = NewPRContext.Branch

    var label: String
    var selection: String
    /// Loaded branches, most recent first.
    var branches: [Branch]
    /// False when `branches` is a truncated list: typing then also searches GitHub.
    var isComplete: Bool
    var search: (String) async -> [Branch]
    var onSelect: (Branch) -> Void
    @State private var isOpen = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button { isOpen = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(selection.isEmpty ? "Choisir une branche…" : selection)
                        .font(Theme.mono)
                        .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isOpen ? Theme.blue.opacity(0.6) : Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                BranchSearchList(selection: selection, branches: branches, isComplete: isComplete, search: search) { branch in
                    isOpen = false
                    onSelect(branch)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: branches.isEmpty) {
            if !branches.isEmpty, DebugHooks.openBranchField == label { isOpen = true }
        }
    }
}

private struct BranchSearchList: View {
    typealias Branch = NewPRContext.Branch

    var selection: String
    var branches: [Branch]
    var isComplete: Bool
    var search: (String) async -> [Branch]
    var pick: (Branch) -> Void

    @State private var query = DebugHooks.branchQuery
    @State private var remote: [Branch] = []
    @State private var searching = false
    @State private var highlighted = 0
    /// Pointer position at the last key (arrow or typing): rows that scroll or get filtered under a still pointer
    /// must not steal the highlight, only a pointer that actually moves.
    @State private var pointerAtKeyPress: NSPoint?

    /// Every space-separated term must appear in the name: `feat login` finds `feat/user-login`.
    private var results: [Branch] {
        let terms = query.lowercased().split(separator: " ")
        let matches = { (branch: Branch) in terms.allSatisfy { branch.name.lowercased().contains($0) } }
        let local = branches.filter(matches)
        let known = Set(local.map(\.name))
        return local + remote.filter { !known.contains($0.name) && matches($0) }
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                KeySearchField(text: $query, placeholder: "Rechercher une branche") { step in
                    pointerAtKeyPress = NSEvent.mouseLocation
                    highlighted = min(max(highlighted + step, 0), max(0, results.count - 1))
                } onSubmit: {
                    if results.indices.contains(highlighted) { pick(results[highlighted]) }
                }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, branch in
                            row(branch, isHighlighted: index == highlighted)
                                .id(index)
                                .onHover { inside in
                                    guard inside, NSEvent.mouseLocation != pointerAtKeyPress else { return }
                                    highlighted = index
                                }
                        }
                        if results.isEmpty && !searching {
                            Text(query.isEmpty ? "Aucune branche." : "Aucune branche ne contient « \(query) ».")
                                .font(.callout).foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
            }
            if !isComplete && query.isEmpty {
                Divider()
                Text("\(branches.count) branches chargées sur un plus grand nombre. Tape pour chercher dans toutes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(width: 440, height: 380)
        .onChange(of: query) {
            pointerAtKeyPress = NSEvent.mouseLocation
            highlighted = 0
        }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !isComplete, !text.isEmpty else { remote = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true
            let found = await search(text)
            if !Task.isCancelled { remote = found }
            searching = false
        }
    }

    private func row(_ branch: Branch, isHighlighted: Bool) -> some View {
        Button { pick(branch) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .opacity(branch.name == selection ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(branch.name).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        if let date = branch.committedDate { Text(date.shortAgo) }
                        if let headline = branch.headline { Text("· \(headline)").lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let pr = branch.openPR { Badge(text: "PR #\(pr)", color: Theme.green) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isHighlighted ? Theme.blue.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Search field that takes focus as soon as it is on screen and reports ↑ ↓ ↩. SwiftUI's focus doesn't reliably
/// reach a field inside a popover opened by a click, and the arrows go to the field editor, never to `onKeyPress`.
private struct KeySearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        // While typing, SwiftUI can hand back the text from one keystroke ago: writing it would reset the
        // field editor and throw the insertion point around. The field is the source of truth then.
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeySearchField

        init(parent: KeySearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            default: return false
            }
            return true
        }
    }
}

final class FocusingTextField: NSTextField {
    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        // The popover's window isn't key yet when the field lands in it, and the click that opened it can hand
        // focus back to the sheet: retry over the first moments, and whenever the popover becomes key.
        for delay in [0, 0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.takeFocus(in: window) }
        }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.takeFocus(in: window) }
        }
    }

    /// Never while editing: making the field first responder again selects its text and moves the insertion point.
    private func takeFocus(in window: NSWindow) {
        guard self.window === window else { return }
        if !window.isKeyWindow { window.makeKey() }
        if currentEditor() == nil { window.makeFirstResponder(self) }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }
}
