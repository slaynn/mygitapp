import Foundation

struct DiffLine: Hashable, Identifiable {
    enum Kind: Hashable { case context, addition, deletion, hunkHeader, noNewline }
    var id: Int
    var kind: Kind
    var oldLine: Int?
    var newLine: Int?
    var text: String

    /// The line as it appears in a unified diff.
    var rawText: String {
        switch kind {
        case .context: " " + text
        case .addition: "+" + text
        case .deletion: "-" + text
        case .hunkHeader, .noNewline: text
        }
    }
}

enum DiffParser {
    /// Parses a unified diff patch (one or more hunks) into numbered lines.
    static func parse(_ patch: String) -> [DiffLine] {
        var raw = patch.split(separator: "\n", omittingEmptySubsequences: false)
        if raw.last == "" { raw.removeLast() }
        var lines: [DiffLine] = []
        lines.reserveCapacity(raw.count)
        var old = 0, new = 0
        for (index, line) in raw.enumerated() {
            if line.hasPrefix("@@") {
                if let (o, n) = parseHeader(String(line)) { old = o; new = n }
                lines.append(DiffLine(id: index, kind: .hunkHeader, text: String(line)))
                continue
            }
            let body = String(line.dropFirst())
            switch line.first {
            case "+":
                lines.append(DiffLine(id: index, kind: .addition, newLine: new, text: body))
                new += 1
            case "-":
                lines.append(DiffLine(id: index, kind: .deletion, oldLine: old, text: body))
                old += 1
            case "\\":
                lines.append(DiffLine(id: index, kind: .noNewline, text: String(line)))
            default:
                lines.append(DiffLine(id: index, kind: .context, oldLine: old, newLine: new, text: line.isEmpty ? "" : body))
                old += 1
                new += 1
            }
        }
        return lines
    }

    /// `@@ -12,7 +12,9 @@ ...` → (12, 12)
    static func parseHeader(_ header: String) -> (Int, Int)? {
        let parts = header.components(separatedBy: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ s: String) -> Int? { Int(s.dropFirst().components(separatedBy: ",")[0]) }
        guard let old = start(parts[1]), let new = start(parts[2]) else { return nil }
        return (old, new)
    }

    /// The tail of a review comment's `diffHunk`: GitHub ends the hunk on the commented line, so
    /// the last `span` lines are the target and a few lines above give context.
    static func excerpt(hunk: String, span: Int, context: Int = 5) -> (lines: [DiffLine], highlighted: Set<Int>) {
        let lines = parse(hunk).filter { $0.kind != .hunkHeader }
        let span = max(1, min(span, lines.count))
        let tail = Array(lines.suffix(span + context))
        let highlighted = Set(tail.suffix(span).map(\.id))
        return (tail, highlighted)
    }
}
