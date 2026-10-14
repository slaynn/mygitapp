import Foundation

/// A piece of a comment body: regular markdown, or a `<details>` block rendered collapsed.
enum MarkdownSegment: Hashable {
    case markdown(String)
    case details(summary: String, body: String)
}

/// Normalizes GitHub comment markdown for rendering: the HTML that MarkdownUI can't show
/// (`<sub>`, `<details>`, SVG shields.io badges used by Codex for P0–P3) is rewritten.
enum MarkdownPreprocessor {
    private static let badge = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(https://img\.shields\.io/badge/([^)\s]+)\)"#)
    private static let details = try! NSRegularExpression(
        pattern: #"<details>\s*(?:<summary>(.*?)</summary>)?(.*?)</details>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive])
    private static let priorityPattern = try! NSRegularExpression(pattern: #"img\.shields\.io/badge/(P\d)\b"#)

    static func segments(_ markdown: String) -> [MarkdownSegment] {
        let text = clean(markdown)
        let ns = text as NSString
        var segments: [MarkdownSegment] = []
        var cursor = 0
        for match in details.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                appendMarkdown(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &segments)
            }
            let summary = match.range(at: 1).location == NSNotFound ? "Détails" : ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            segments.append(.details(summary: stripTags(summary).trimmingCharacters(in: .whitespacesAndNewlines),
                                     body: body.trimmingCharacters(in: .whitespacesAndNewlines)))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { appendMarkdown(ns.substring(from: cursor), to: &segments) }
        return segments
    }

    /// Badges → colored emoji + label; HTML that MarkdownUI would print raw is converted or
    /// dropped (outside code); Codex's reaction prompt is removed.
    static func clean(_ markdown: String) -> String {
        var text = replaceBadges(in: markdown) { badgeText($0) }
        text = transformOutsideCode(text, sanitizeHTML)
        return removeReactionPrompt(text)
    }

    /// Plain markdown for agent handoff: badges become `[P1]`, collapsed boilerplate and
    /// reaction prompts are dropped.
    static func plainText(_ markdown: String) -> String {
        var text = replaceBadges(in: markdown) { "[\(badgeLabel($0).label)]" }
        text = details.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        text = transformOutsideCode(text, sanitizeHTML)
        return removeReactionPrompt(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeReactionPrompt(_ text: String) -> String {
        text.replacingOccurrences(of: #"\n?Useful\? React with 👍 / 👎\.?"#, with: "", options: .regularExpression)
    }

    /// Inline HTML → markdown equivalents. `<details>`/`<summary>` are kept for `segments`.
    static func sanitizeHTML(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            (#"<!--[\s\S]*?-->"#, ""),
            (#"<br\s*/?>"#, "\n"),
            (#"</?(?:b|strong)>"#, "**"),
            (#"</?(?:i|em)>"#, "*"),
            (#"</?code>"#, "`"),
            (#"<a\s[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#, "[$2]($1)"),
            (#"<img\s[^>]*src="([^"]+)"[^>]*/?>"#, "![]($1)"),
            (#"</?(?:sub|sup|p|span|div|relative-time|picture|source|kbd|ins|small|center|font|a)\b[^>]*>"#, ""),
        ]
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        if out.contains(":") {
            for (code, emoji) in shortcodes { out = out.replacingOccurrences(of: code, with: emoji) }
        }
        return out
    }

    /// The GitHub emoji shortcodes bots use most.
    private static let shortcodes: [(String, String)] = [
        (":white_check_mark:", "✅"), (":heavy_check_mark:", "✔️"), (":x:", "❌"), (":warning:", "⚠️"),
        (":cloud:", "☁️"), (":rocket:", "🚀"), (":tada:", "🎉"), (":bulb:", "💡"), (":memo:", "📝"),
        (":mag:", "🔍"), (":eyes:", "👀"), (":+1:", "👍"), (":-1:", "👎"), (":thumbsup:", "👍"),
        (":thumbsdown:", "👎"), (":fire:", "🔥"), (":bug:", "🐛"), (":sparkles:", "✨"), (":lock:", "🔒"),
        (":information_source:", "ℹ️"), (":hourglass:", "⌛"), (":construction:", "🚧"), (":link:", "🔗"),
        (":red_circle:", "🔴"), (":green_circle:", "🟢"), (":yellow_circle:", "🟡"), (":robot:", "🤖"),
        (":package:", "📦"), (":zap:", "⚡"), (":recycle:", "♻️"), (":boom:", "💥"), (":heavy_minus_sign:", "➖"),
    ]

    /// Applies `transform` to prose only: fenced blocks and `inline code` are left untouched.
    static func transformOutsideCode(_ text: String, _ transform: (String) -> String) -> String {
        var out: [String] = []
        var prose: [String] = []
        var fence: String?
        func flush() {
            guard !prose.isEmpty else { return }
            let parts = prose.joined(separator: "\n").components(separatedBy: "`")
            out.append(parts.enumerated().map { $0.offset.isMultiple(of: 2) ? transform($0.element) : $0.element }.joined(separator: "`"))
            prose = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                out.append(line)
                if trimmed.hasPrefix(marker) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = String(trimmed.prefix(3))
                out.append(line)
            } else {
                prose.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// `P0`…`P3` from a Codex comment badge.
    static func priority(in markdown: String) -> String? {
        let ns = markdown as NSString
        guard let match = priorityPattern.firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// `P2-yellow?style=flat` → (`P2`, `yellow`)
    static func badgeLabel(_ spec: String) -> (label: String, color: String) {
        let path = spec.split(separator: "?").first.map(String.init) ?? spec
        var parts = (path.removingPercentEncoding ?? path).split(separator: "-").map(String.init)
        let color = parts.count > 1 ? parts.removeLast() : ""
        return (parts.joined(separator: " "), color)
    }

    /// `P2-yellow?style=flat` → `🟡 P2`
    static func badgeText(_ spec: String) -> String {
        let (label, color) = badgeLabel(spec)
        let emoji: String = switch color.lowercased() {
        case "red", "critical", "important": "🔴"
        case "orange": "🟠"
        case "yellow": "🟡"
        case "green", "brightgreen", "success": "🟢"
        case "blue", "informational": "🔵"
        default: "⚪️"
        }
        return "\(emoji) \(label)"
    }

    private static func replaceBadges(in markdown: String, _ transform: (String) -> String) -> String {
        let ns = markdown as NSString
        var out = ""
        var cursor = 0
        for match in badge.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += transform(ns.substring(with: match.range(at: 1)))
            cursor = match.range.location + match.range.length
        }
        return out + ns.substring(from: cursor)
    }

    private static func appendMarkdown(_ text: String, to segments: inout [MarkdownSegment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments.append(.markdown(trimmed)) }
    }

    /// Summaries render as plain text: drop leftover tags and emphasis markers.
    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
    }
}
