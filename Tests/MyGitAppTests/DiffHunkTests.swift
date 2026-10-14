import Testing
@testable import MyGitApp

@Suite struct DiffHunkTests {
    let patch = """
    @@ -10,4 +10,5 @@ func a() {
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
     return a
    \\ No newline at end of file
    @@ -40,2 +41,2 @@
    -old()
    +new()

    """

    @Test func numbersLinesAcrossHunks() {
        let lines = DiffParser.parse(patch)
        #expect(lines.map(\.kind) == [.hunkHeader, .context, .deletion, .addition, .addition, .context, .noNewline,
                                      .hunkHeader, .deletion, .addition])
        #expect(lines[1].oldLine == 10 && lines[1].newLine == 10)
        #expect(lines[2].oldLine == 11 && lines[2].newLine == nil)
        #expect(lines[3].newLine == 11)
        #expect(lines[4].newLine == 12)
        #expect(lines[5].oldLine == 12 && lines[5].newLine == 13)
        #expect(lines[8].oldLine == 40)
        #expect(lines[9].newLine == 41)
        #expect(lines[3].text == "let b = 3")
        #expect(lines[3].rawText == "+let b = 3")
    }

    @Test func parsesHeaders() {
        #expect(DiffParser.parseHeader("@@ -1 +1 @@")! == (1, 1))
        #expect(DiffParser.parseHeader("@@ -12,7 +15,9 @@ context")! == (12, 15))
        #expect(DiffParser.parseHeader("not a header") == nil)
    }

    @Test func excerptHighlightsTheCommentedTail() {
        let hunk = """
        @@ -1,8 +1,8 @@
         one
         two
         three
         four
         five
         six
        -seven
        +SEVEN
        """
        let excerpt = DiffParser.excerpt(hunk: hunk, span: 2, context: 3)
        #expect(excerpt.lines.map(\.text) == ["four", "five", "six", "seven", "SEVEN"])
        #expect(excerpt.highlighted == Set(excerpt.lines.suffix(2).map(\.id)))
    }

    @Test func excerptClampsSpan() {
        let excerpt = DiffParser.excerpt(hunk: "@@ -1 +1 @@\n+only", span: 10)
        #expect(excerpt.lines.count == 1)
        #expect(excerpt.highlighted.count == 1)
    }
}

@Suite struct MarkdownPreprocessorTests {
    let codex = "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  Fix it**\n\nBody.\n\nUseful? React with 👍 / 👎."

    @Test func replacesBadgesAndLayoutTags() {
        let cleaned = MarkdownPreprocessor.clean(codex)
        #expect(cleaned.hasPrefix("**🟠 P1  Fix it**"))
        #expect(!cleaned.contains("<sub>"))
    }

    @Test func convertsBotHTMLButLeavesCodeAlone() {
        let md = """
        <!-- codex-pull-request-review-summary -->
        Done <relative-time datetime="2026">2026-09-08</relative-time> by <b>bot</b><br/>see <a href="https://x.y">link</a>
        Inline `<div>kept</div>` here.
        ```html
        <!-- kept --><div>kept</div>
        ```
        """
        let cleaned = MarkdownPreprocessor.clean(md)
        #expect(cleaned == """

        Done 2026-09-08 by **bot**
        see [link](https://x.y)
        Inline `<div>kept</div>` here.
        ```html
        <!-- kept --><div>kept</div>
        ```
        """)
    }

    @Test func expandsCommonShortcodesOutsideCode() {
        #expect(MarkdownPreprocessor.clean(":cloud: Deployed `:x:`") == "☁️ Deployed `:x:`")
    }

    @Test func dropsReactionPromptFromDisplay() {
        #expect(!MarkdownPreprocessor.clean(codex).contains("Useful?"))
        // Exact bytes sent by Codex: a non-breaking space after 👍.
        let real = "Fix it.\n\nUseful? React with 👍\u{00A0}/ 👎.\n"
        #expect(MarkdownPreprocessor.clean(real).trimmingCharacters(in: .whitespacesAndNewlines) == "Fix it.")
    }

    @Test func extractsPriority() {
        #expect(MarkdownPreprocessor.priority(in: codex) == "P1")
        #expect(MarkdownPreprocessor.priority(in: "plain") == nil)
    }

    @Test func splitsDetailsBlocks() {
        let md = "Intro\n\n<details> <summary>ℹ️ About <b>Codex</b></summary>\n<br/>\nHidden text\n</details>\n\nOutro"
        let segments = MarkdownPreprocessor.segments(md)
        #expect(segments == [.markdown("Intro"), .details(summary: "ℹ️ About Codex", body: "Hidden text"), .markdown("Outro")])
    }

    @Test func plainTextForAgents() {
        let text = MarkdownPreprocessor.plainText(codex + "\n<details><summary>x</summary>y</details>")
        #expect(text == "**[P1]  Fix it**\n\nBody.")
    }

    @Test func badgeTextHandlesLabelsWithDashesAndUnknownColors() {
        #expect(MarkdownPreprocessor.badgeText("P0-red") == "🔴 P0")
        #expect(MarkdownPreprocessor.badgeText("build-passing-brightgreen?style=flat") == "🟢 build passing")
        #expect(MarkdownPreprocessor.badgeText("x-ff00aa") == "⚪️ x")
    }
}
