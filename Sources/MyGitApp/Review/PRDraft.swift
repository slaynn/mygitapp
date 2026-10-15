import Foundation

/// Prefills a new pull request from its branch and commits, the way GitHub does.
enum PRDraft {
    /// One commit: its subject. Several: the branch name made readable, unless it carries no words
    /// (`t3code/88d456c9`), then the latest commit's subject.
    static func title(branch: String, commitMessages: [String]) -> String {
        let subjects = commitMessages.map(subject)
        if subjects.count == 1 { return subjects[0] }
        return humanize(branch: branch) ?? subjects.last ?? branch
    }

    /// The repo's PR template when there is one; otherwise the commit body (one commit) or the list
    /// of commit subjects (several).
    static func body(commitMessages: [String], template: String?) -> String {
        if let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return template }
        if commitMessages.count == 1 {
            let parts = commitMessages[0].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? stripTrailers(String(parts[1])) : ""
        }
        return commitMessages.map { "- " + subject($0) }.joined(separator: "\n")
    }

    /// `feat/add-login_form` → `Add login form`; nil for names without words (`88d456c9`).
    static func humanize(branch: String) -> String? {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map(String.init)
        guard words.contains(where: { word in word.count >= 2 && !word.allSatisfy(\.isHexDigit) && word.contains(where: \.isLetter) })
        else { return nil }
        let sentence = words.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    static func subject(_ message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Drops `Co-Authored-By:` / `Signed-off-by:` lines, which don't belong in a PR description.
    private static func stripTrailers(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !["co-authored-by:", "signed-off-by:"].contains { line.lowercased().hasPrefix($0) } }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
