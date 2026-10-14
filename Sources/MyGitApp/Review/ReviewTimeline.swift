import Foundation

/// A submitted review with the threads it opened. Replies posted later (which GitHub records as
/// separate, body-less reviews) stay inside their thread instead of becoming timeline noise.
struct ReviewGroup: Hashable, Identifiable {
    var review: Review
    var threads: [ReviewThread]
    var id: String { review.id }
}

enum TimelineEntry: Hashable, Identifiable {
    case review(ReviewGroup)
    case orphanThread(ReviewThread)
    case comment(IssueComment)
    case commits([CommitInfo])
    case event(type: String, SimpleEvent)

    var id: String {
        switch self {
        case .review(let g): g.id
        case .orphanThread(let t): t.id
        case .comment(let c): c.id
        case .commits(let c): "commits-" + (c.first?.oid ?? "")
        case .event(_, let e): e.id
        }
    }

    var date: Date {
        switch self {
        case .review(let g): g.review.submittedAt ?? g.review.createdAt
        case .orphanThread(let t): t.root?.createdAt ?? .distantPast
        case .comment(let c): c.createdAt
        case .commits(let c): c.first?.committedDate ?? .distantPast
        case .event(_, let e): e.createdAt
        }
    }
}

enum ReviewTimeline {
    /// Review states that are worth showing even without a body or threads.
    private static let significantStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]

    static func build(reviews: [Review], threads: [ReviewThread], items: [TimelineNode]) -> [TimelineEntry] {
        let visibleReviews = reviews.filter { $0.state != "PENDING" }
        let reviewIDs = Set(visibleReviews.map(\.id))

        var threadsByReview: [String: [ReviewThread]] = [:]
        var orphans: [ReviewThread] = []
        for thread in threads {
            if let reviewID = thread.root?.pullRequestReview?.id, reviewIDs.contains(reviewID) {
                threadsByReview[reviewID, default: []].append(thread)
            } else if thread.root != nil {
                orphans.append(thread)
            }
        }

        var entries: [TimelineEntry] = []
        for review in visibleReviews {
            let owned = threadsByReview[review.id] ?? []
            let hasBody = !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasBody || !owned.isEmpty || significantStates.contains(review.state) else { continue }
            entries.append(.review(ReviewGroup(review: review, threads: owned)))
        }
        entries += orphans.map(TimelineEntry.orphanThread)
        for item in items {
            switch item {
            case .comment(let c): entries.append(.comment(c))
            case .commit(let c): entries.append(.commits([c]))
            case .event(let type, let e): entries.append(.event(type: type, e))
            case .unknown: break
            }
        }

        // Stable sort by date, then fold consecutive pushes into one block.
        let sorted = entries.enumerated()
            .sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date }
            .map(\.element)
        var result: [TimelineEntry] = []
        for entry in sorted {
            if case .commits(let new) = entry, case .commits(let previous)? = result.last {
                result[result.count - 1] = .commits(previous + new)
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// Threads grouped by file, files in first-appearance order, threads by line.
    static func threadsByFile(_ threads: [ReviewThread]) -> [(path: String, threads: [ReviewThread])] {
        var order: [String] = []
        var groups: [String: [ReviewThread]] = [:]
        for thread in threads {
            if groups[thread.path] == nil { order.append(thread.path) }
            groups[thread.path, default: []].append(thread)
        }
        return order.map { path in
            (path, groups[path]!.sorted { ($0.displayLine ?? 0) < ($1.displayLine ?? 0) })
        }
    }

    /// Markdown handoff for a coding agent: location, code excerpt and the full discussion.
    static func agentPrompt(for threads: [ReviewThread], pr: PRRef?) -> String {
        var out = ""
        if let pr {
            out += "Review comments to address on \(pr.nameWithOwner)#\(pr.number):\n\n"
        }
        for (index, thread) in threads.enumerated() {
            let priority = thread.priority.map { " [\($0)]" } ?? ""
            out += threads.count > 1 ? "### \(index + 1). \(thread.location)\(priority)\n\n" : "### \(thread.location)\(priority)\n\n"
            if let hunk = thread.root?.diffHunk {
                let excerpt = DiffParser.excerpt(hunk: hunk, span: thread.spanLength)
                let code = excerpt.lines.map { $0.rawText }.joined(separator: "\n")
                if !code.isEmpty { out += "```diff\n\(code)\n```\n\n" }
            }
            for (i, comment) in thread.comments.nodes.enumerated() {
                let author = comment.author?.login ?? "ghost"
                let body = MarkdownPreprocessor.plainText(comment.body)
                if i == 0 {
                    out += "**\(author)**:\n\(body)\n\n"
                } else {
                    out += "> **\(author)** replied:\n" + body.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
                }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
