import Foundation
import Testing
@testable import MyGitApp

private func loadFixture() throws -> PRDetail {
    struct R: Decodable {
        struct D: Decodable { struct Repo: Decodable { var pullRequest: PRDetail }; var repository: Repo }
        var data: D
    }
    let url = try #require(Bundle.module.url(forResource: "pr-detail", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder.github.decode(R.self, from: Data(contentsOf: url)).data.repository.pullRequest
}

@Suite struct PRDetailDecodingTests {
    @Test func decodesSummaryAndExtra() throws {
        let pr = try loadFixture()
        #expect(pr.summary.number == 42)
        #expect(pr.summary.ref == PRRef(owner: "acme", name: "app", number: 42))
        #expect(pr.summary.unresolvedCount == 2)
        #expect(pr.summary.ci == .failure)
        #expect(pr.extra.reviews.nodes.count == 4)
        #expect(pr.extra.reviewThreads.nodes.count == 3)
        #expect(pr.extra.repository.rebaseMergeAllowed == false)
        #expect(pr.extra.reviewRequests.nodes.first?.requestedReviewer?.display == "core")
    }

    @Test func normalizesChecks() throws {
        let checks = try loadFixture().extra.checks
        #expect(checks.map(\.name) == ["test", "lint", "vercel"])
        #expect(checks.map(\.status) == [.failure, .pending, .success])
        #expect(checks[0].workflow == "CI")
        #expect(checks[2].detail == "Deployed")
    }

    @Test func survivesDiskCacheRoundTrip() throws {
        let pr = try loadFixture()
        let data = try JSONEncoder.github.encode(pr)
        let decoded = try JSONDecoder.github.decode(PRDetail.self, from: data)
        #expect(decoded == pr)
    }
}

@Suite struct ReviewTimelineTests {
    @Test func ordersEntriesAndNestsThreadsUnderTheirReview() throws {
        let pr = try loadFixture()
        let timeline = ReviewTimeline.build(reviews: pr.extra.reviews.nodes,
                                            threads: pr.extra.reviewThreads.nodes,
                                            items: pr.extra.timelineItems.nodes)
        let ids = timeline.map(\.id)
        #expect(ids == ["commits-1a2b3c41a2b3c41a2b3c41a2b3c41a2b3c4", "R_codex", "FP_1",
                        "commits-2c3d4e52c3d4e52c3d4e52c3d4e52c3d4e5", "IC_1", "R_approve"])

        guard case .review(let codex) = timeline[1] else { Issue.record("expected review"); return }
        #expect(codex.threads.map(\.id) == ["T_1", "T_2"])
        // The reply posted from a later review stays inside its thread.
        #expect(codex.threads[0].comments.nodes.map(\.id) == ["C_1", "C_2"])
    }

    @Test func foldsConsecutiveCommits() throws {
        let pr = try loadFixture()
        let timeline = ReviewTimeline.build(reviews: [], threads: [], items: pr.extra.timelineItems.nodes)
        guard case .commits(let first) = timeline.first else { Issue.record("expected commits"); return }
        #expect(first.count == 2)
    }

    @Test func dropsPendingAndReplyOnlyReviews() throws {
        let pr = try loadFixture()
        let timeline = ReviewTimeline.build(reviews: pr.extra.reviews.nodes, threads: pr.extra.reviewThreads.nodes, items: [])
        let reviewIDs = timeline.compactMap { entry -> String? in
            if case .review(let g) = entry { return g.id } else { return nil }
        }
        #expect(reviewIDs == ["R_codex", "R_approve"])
    }

    @Test func threadWithUnknownReviewBecomesOrphan() throws {
        let pr = try loadFixture()
        let timeline = ReviewTimeline.build(reviews: [], threads: pr.extra.reviewThreads.nodes, items: [])
        #expect(timeline.count == 3)
        #expect(timeline.allSatisfy { if case .orphanThread = $0 { true } else { false } })
    }

    @Test func groupsThreadsByFileSortedByLine() throws {
        let pr = try loadFixture()
        let groups = ReviewTimeline.threadsByFile(pr.extra.reviewThreads.nodes)
        #expect(groups.map(\.path) == ["src/panel.tsx", "src/index.ts"])
        #expect(groups[0].threads.map(\.id) == ["T_3", "T_1"])
    }

    @Test func threadDerivedProperties() throws {
        let threads = try loadFixture().extra.reviewThreads.nodes
        #expect(threads[0].priority == "P1")
        #expect(threads[0].spanLength == 2)
        #expect(threads[0].location == "src/panel.tsx:12")
        #expect(threads[2].displayLine == 4)
        #expect(threads[2].spanLength == 1)
    }

    @Test func agentPromptCarriesLocationCodeAndDiscussion() throws {
        let pr = try loadFixture()
        let prompt = ReviewTimeline.agentPrompt(for: [pr.extra.reviewThreads.nodes[0]], pr: pr.summary.ref)
        #expect(prompt.contains("acme/app#42"))
        #expect(prompt.contains("### src/panel.tsx:12 [P1]"))
        #expect(prompt.contains("```diff\n"))
        #expect(prompt.contains("+    showToggle();"))
        #expect(prompt.contains("[P1]  Block archiving"))
        #expect(prompt.contains("> **slaynn** replied:\n> Fixed in 2c3d4e5."))
        #expect(!prompt.contains("shields.io"))
        #expect(!prompt.contains("Useful?"))
    }
}
