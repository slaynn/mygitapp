import AppKit
import SwiftUI

/// Search field for keyboard-driven lists (branch search, ⌘K): takes focus as soon as it is on screen and reports
/// ↑ ↓ ↩ and Escape. SwiftUI's focus doesn't reliably reach a field inside a popover opened by a click, and the
/// arrows go to the field editor, never to `onKeyPress`.
struct KeySearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 13
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    /// Escape; when nil, it goes up the responder chain (a popover closes itself).
    var onCancel: (() -> Void)?

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
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
            case #selector(NSResponder.cancelOperation(_:)) where parent.onCancel != nil: parent.onCancel?()
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
