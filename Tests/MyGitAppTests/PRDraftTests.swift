import Testing
@testable import MyGitApp

@Suite struct PRDraftTests {
    @Test func singleCommitGivesTitleAndBody() {
        let message = "Fix login redirect\n\nThe callback dropped the query string.\n\nCo-Authored-By: Bot <bot@example.com>"
        #expect(PRDraft.title(branch: "fix/login", commitMessages: [message]) == "Fix login redirect")
        #expect(PRDraft.body(commitMessages: [message], template: nil) == "The callback dropped the query string.")
    }

    @Test func severalCommitsUseBranchNameAndListSubjects() {
        let messages = ["Add form\n\ndetails", "Validate email"]
        #expect(PRDraft.title(branch: "feat/add-login_form", commitMessages: messages) == "Add login form")
        #expect(PRDraft.body(commitMessages: messages, template: nil) == "- Add form\n- Validate email")
    }

    @Test func branchWithoutWordsFallsBackToLatestCommit() {
        #expect(PRDraft.humanize(branch: "t3code/88d456c9") == nil)
        #expect(PRDraft.title(branch: "t3code/88d456c9", commitMessages: ["First", "Second"]) == "Second")
    }

    @Test func templateWins() {
        #expect(PRDraft.body(commitMessages: ["A", "B"], template: "## Pourquoi\n") == "## Pourquoi\n")
        #expect(PRDraft.body(commitMessages: ["A", "B"], template: "  \n") == "- A\n- B")
    }
}
