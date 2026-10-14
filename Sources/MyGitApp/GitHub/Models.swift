import Foundation

// Codable mirrors of the GraphQL shapes in Queries.swift. Every model is Codable so it can be
// written to the disk cache as-is.

struct Nodes<T: Codable & Hashable>: Codable, Hashable {
    var nodes: [T]
}

struct TotalCount: Codable, Hashable {
    var totalCount: Int
}

struct PageInfo: Codable, Hashable {
    var hasNextPage: Bool
    var endCursor: String?
}

struct GHActor: Codable, Hashable {
    var login: String
    var avatarUrl: URL?
}

struct RepoName: Codable, Hashable {
    var nameWithOwner: String
}

struct StatusRollup: Codable, Hashable {
    var state: String
    var ci: CIStatus { CIStatus(rollup: state) }
}

/// Normalized CI state across rollups, check runs and status contexts.
enum CIStatus: String, Codable, Hashable {
    case success, failure, pending, neutral, none

    init(rollup: String?) {
        switch rollup {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        case nil: self = .none
        default: self = .neutral
        }
    }

    init(checkStatus: String?, conclusion: String?) {
        guard checkStatus == "COMPLETED" else { self = .pending; return }
        switch conclusion {
        case "SUCCESS": self = .success
        case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED": self = .failure
        case "CANCELLED", "SKIPPED", "NEUTRAL", "STALE": self = .neutral
        default: self = .neutral
        }
    }
}

// MARK: - Pull requests

struct PRRef: Codable, Hashable, Identifiable {
    var owner: String
    var name: String
    var number: Int

    var id: String { "\(owner)/\(name)#\(number)" }
    var nameWithOwner: String { "\(owner)/\(name)" }
    var htmlURL: URL { URL(string: "https://github.com/\(owner)/\(name)/pull/\(number)")! }

    init(owner: String, name: String, number: Int) {
        self.owner = owner
        self.name = name
        self.number = number
    }

    init?(nameWithOwner: String, number: Int) {
        let parts = nameWithOwner.split(separator: "/")
        guard parts.count == 2 else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]), number: number)
    }
}

struct ResolvedFlag: Codable, Hashable {
    var isResolved: Bool
}

struct CommitRollupWrapper: Codable, Hashable {
    struct Commit: Codable, Hashable { var statusCheckRollup: StatusRollup? }
    var commit: Commit
}

struct PRSummary: Codable, Hashable, Identifiable {
    var id: String
    var number: Int
    var title: String
    var url: URL
    var state: String
    var isDraft: Bool
    var createdAt: Date
    var updatedAt: Date
    var author: GHActor?
    var repository: RepoName
    var headRefName: String
    var baseRefName: String
    var additions: Int
    var deletions: Int
    var reviewDecision: String?
    var comments: TotalCount
    var reviewThreads: Nodes<ResolvedFlag>
    var commits: Nodes<CommitRollupWrapper>

    var ref: PRRef { PRRef(nameWithOwner: repository.nameWithOwner, number: number)! }
    var unresolvedCount: Int { reviewThreads.nodes.filter { !$0.isResolved }.count }
    var ci: CIStatus { CIStatus(rollup: commits.nodes.last?.commit.statusCheckRollup?.state) }
}

struct PRDetail: Codable, Hashable {
    var summary: PRSummary
    var extra: PRDetailExtra

    init(from decoder: Decoder) throws {
        summary = try PRSummary(from: decoder)
        extra = try PRDetailExtra(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        try extra.encode(to: encoder)
    }
}

struct PRDetailExtra: Codable, Hashable {
    /// Shares the `repository` key with `PRSummary.repository`, so it must carry `nameWithOwner`
    /// too: it is encoded last and overwrites the summary's copy in the disk cache.
    struct RepoMergeSettings: Codable, Hashable {
        var nameWithOwner: String
        var mergeCommitAllowed: Bool?
        var squashMergeAllowed: Bool?
        var rebaseMergeAllowed: Bool?
    }

    struct ReviewRequest: Codable, Hashable {
        struct Reviewer: Codable, Hashable {
            var login: String?
            var name: String?
            var avatarUrl: URL?
            var display: String { login ?? name ?? "?" }
        }
        var requestedReviewer: Reviewer?
    }

    struct LastCommit: Codable, Hashable {
        struct Commit: Codable, Hashable {
            struct Rollup: Codable, Hashable {
                var state: String
                var contexts: Nodes<CheckItem>
            }
            var oid: String
            var statusCheckRollup: Rollup?
        }
        var commit: Commit
    }

    var body: String
    var headRefOid: String
    var changedFiles: Int
    var mergeable: String
    var mergeStateStatus: String
    var viewerDidAuthor: Bool
    var viewerCanUpdate: Bool
    var merged: Bool
    var repository: RepoMergeSettings
    var reviewRequests: Nodes<ReviewRequest>
    var reviews: Nodes<Review>
    var reviewThreads: Nodes<ReviewThread>
    var timelineItems: Nodes<TimelineNode>
    var lastCommit: Nodes<LastCommit>

    var checks: [CheckItem] { lastCommit.nodes.last?.commit.statusCheckRollup?.contexts.nodes ?? [] }
}

struct Review: Codable, Hashable, Identifiable {
    var id: String
    var author: GHActor?
    var state: String
    var body: String
    var submittedAt: Date?
    var createdAt: Date
    var url: URL
}

struct ReviewComment: Codable, Hashable, Identifiable {
    struct ReviewID: Codable, Hashable { var id: String }
    var id: String
    var author: GHActor?
    var body: String
    var createdAt: Date
    var url: URL
    var diffHunk: String
    var outdated: Bool
    var pullRequestReview: ReviewID?
}

struct ReviewThread: Codable, Hashable, Identifiable {
    var id: String
    var isResolved: Bool
    var isOutdated: Bool
    var path: String
    var line: Int?
    var originalLine: Int?
    var startLine: Int?
    var originalStartLine: Int?
    var diffSide: String
    var viewerCanResolve: Bool
    var viewerCanUnresolve: Bool
    var viewerCanReply: Bool
    var resolvedBy: GHActor?
    var comments: Nodes<ReviewComment>

    var root: ReviewComment? { comments.nodes.first }
    var replies: ArraySlice<ReviewComment> { comments.nodes.dropFirst() }
    var displayLine: Int? { line ?? originalLine }
    /// Number of diff lines the thread covers (multi-line comments).
    var spanLength: Int {
        let end = line ?? originalLine
        let start = startLine ?? originalStartLine
        guard let end, let start, end >= start else { return 1 }
        return end - start + 1
    }
    var location: String { displayLine.map { "\(path):\($0)" } ?? path }
    var priority: String? { root.flatMap { MarkdownPreprocessor.priority(in: $0.body) } }
}

struct GitActor: Codable, Hashable {
    struct User: Codable, Hashable { var login: String }
    var name: String?
    var avatarUrl: URL?
    var user: User?
    var display: String { user?.login ?? name ?? "unknown" }
}

struct CommitInfo: Codable, Hashable, Identifiable {
    var oid: String
    var abbreviatedOid: String
    var messageHeadline: String
    var committedDate: Date
    var url: URL
    var author: GitActor?
    var statusCheckRollup: StatusRollup?
    var id: String { oid }
}

struct IssueComment: Codable, Hashable, Identifiable {
    var id: String
    var author: GHActor?
    var body: String
    var createdAt: Date
    var url: URL
}

struct SimpleEvent: Codable, Hashable, Identifiable {
    struct ShortCommit: Codable, Hashable { var abbreviatedOid: String }
    var id: String
    var createdAt: Date
    var actor: GHActor?
    var beforeCommit: ShortCommit?
    var afterCommit: ShortCommit?
}

enum TimelineNode: Codable, Hashable {
    case comment(IssueComment)
    case commit(CommitInfo)
    case event(type: String, SimpleEvent)
    case unknown(String)

    private enum Keys: String, CodingKey { case __typename, commit }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .__typename)
        switch type {
        case "IssueComment": self = .comment(try IssueComment(from: decoder))
        case "PullRequestCommit": self = .commit(try c.decode(CommitInfo.self, forKey: .commit))
        case "HeadRefForcePushedEvent", "MergedEvent", "ClosedEvent", "ReopenedEvent", "ReadyForReviewEvent":
            self = .event(type: type, try SimpleEvent(from: decoder))
        default: self = .unknown(type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .comment(let v):
            try c.encode("IssueComment", forKey: .__typename)
            try v.encode(to: encoder)
        case .commit(let v):
            try c.encode("PullRequestCommit", forKey: .__typename)
            try c.encode(v, forKey: .commit)
        case .event(let type, let v):
            try c.encode(type, forKey: .__typename)
            try v.encode(to: encoder)
        case .unknown(let type):
            try c.encode(type, forKey: .__typename)
        }
    }
}

/// A CheckRun or a StatusContext, normalized.
struct CheckItem: Codable, Hashable, Identifiable {
    var name: String
    var workflow: String?
    var status: CIStatus
    var detail: String?
    var url: URL?
    var startedAt: Date?
    var completedAt: Date?
    var id: String { (workflow ?? "") + "/" + name }

    private enum Keys: String, CodingKey {
        case __typename, name, status, conclusion, detailsUrl, startedAt, completedAt, checkSuite
        case context, state, description, targetUrl, createdAt
        // cache format
        case workflow, ciStatus, detail, url
    }
    private struct Suite: Decodable { struct Run: Decodable { struct W: Decodable { var name: String }; var workflow: W }; var workflowRun: Run? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .__typename)
        switch type {
        case "CheckRun":
            name = try c.decode(String.self, forKey: .name)
            let status = try c.decodeIfPresent(String.self, forKey: .status)
            let conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
            self.status = CIStatus(checkStatus: status, conclusion: conclusion)
            detail = conclusion?.lowercased() ?? status?.lowercased()
            url = try c.decodeIfPresent(URL.self, forKey: .detailsUrl)
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
            workflow = try c.decodeIfPresent(Suite.self, forKey: .checkSuite)?.workflowRun?.workflow.name
        case "StatusContext":
            name = try c.decode(String.self, forKey: .context)
            status = CIStatus(rollup: try c.decodeIfPresent(String.self, forKey: .state))
            detail = try c.decodeIfPresent(String.self, forKey: .description)
            url = try c.decodeIfPresent(URL.self, forKey: .targetUrl)
            startedAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
            completedAt = nil
            workflow = nil
        default:
            name = try c.decode(String.self, forKey: .name)
            workflow = try c.decodeIfPresent(String.self, forKey: .workflow)
            status = try c.decode(CIStatus.self, forKey: .ciStatus)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
            url = try c.decodeIfPresent(URL.self, forKey: .url)
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(workflow, forKey: .workflow)
        try c.encode(status, forKey: .ciStatus)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

// MARK: - Repositories

struct Language: Codable, Hashable {
    var name: String
    var color: String?
}

struct RepoOverview: Codable, Hashable {
    struct License: Codable, Hashable { var spdxId: String?; var name: String }
    struct Languages: Codable, Hashable {
        struct Edge: Codable, Hashable { var size: Int; var node: Language }
        var totalSize: Int
        var edges: [Edge]
    }
    struct Topic: Codable, Hashable { struct T: Codable, Hashable { var name: String }; var topic: T }
    struct BranchRef: Codable, Hashable {
        struct Target: Codable, Hashable { var history: Nodes<CommitInfo>? }
        var name: String
        var target: Target?
    }
    struct Release: Codable, Hashable { var tagName: String; var name: String?; var publishedAt: Date?; var url: URL }
    struct PullRequests: Codable, Hashable { var totalCount: Int; var nodes: [PRSummary] }

    var id: String
    var nameWithOwner: String
    var name: String
    var description: String?
    var url: URL
    var homepageUrl: String?
    var isPrivate: Bool
    var isFork: Bool
    var isArchived: Bool
    var stargazerCount: Int
    var forkCount: Int
    var viewerHasStarred: Bool
    var pushedAt: Date?
    var updatedAt: Date
    var sshUrl: String
    var owner: GHActor
    var licenseInfo: License?
    var primaryLanguage: Language?
    var languages: Languages
    var repositoryTopics: Nodes<Topic>
    var defaultBranchRef: BranchRef?
    var latestRelease: Release?
    var releases: TotalCount
    var pullRequests: PullRequests

    var recentCommits: [CommitInfo] { defaultBranchRef?.target?.history?.nodes ?? [] }
    var cloneURL: String { url.absoluteString + ".git" }
}

struct RepoListItem: Codable, Hashable, Identifiable {
    var nameWithOwner: String
    var description: String?
    var isPrivate: Bool
    var isArchived: Bool
    var isFork: Bool
    var stargazerCount: Int
    var pushedAt: Date?
    var owner: GHActor
    var id: String { nameWithOwner }
}

struct RepoSummary: Codable, Hashable {
    struct Owner: Codable, Hashable { var avatarUrl: URL? }
    var nameWithOwner: String
    var stargazerCount: Int
    var owner: Owner
    var pullRequests: TotalCount
}

struct Viewer: Codable, Hashable {
    var login: String
    var name: String?
    var avatarUrl: URL?
}

// MARK: - REST

struct PRFile: Codable, Hashable, Identifiable {
    var filename: String
    var status: String
    var additions: Int
    var deletions: Int
    var patch: String?
    var previous_filename: String?
    var id: String { filename }
}

struct Contributor: Codable, Hashable, Identifiable {
    var login: String
    var avatar_url: URL?
    var contributions: Int
    var id: String { login }
}

struct GHNotification: Codable, Hashable, Identifiable {
    struct Subject: Codable, Hashable {
        var title: String
        var url: String?
        var type: String
    }
    struct Repo: Codable, Hashable {
        struct Owner: Codable, Hashable { var avatar_url: URL? }
        var full_name: String
        var owner: Owner?
    }
    var id: String
    var unread: Bool
    var reason: String
    var updated_at: Date
    var subject: Subject
    var repository: Repo

    /// The PR this notification points to, if any.
    var pullRequest: PRRef? {
        guard subject.type == "PullRequest", let url = subject.url,
              let number = url.split(separator: "/").last.flatMap({ Int($0) }) else { return nil }
        return PRRef(nameWithOwner: repository.full_name, number: number)
    }

    /// Browser URL for the subject (API URLs are converted to html URLs).
    var htmlURL: URL {
        if let url = subject.url {
            let html = url
                .replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
                .replacingOccurrences(of: "/pulls/", with: "/pull/")
                .replacingOccurrences(of: "/commits/", with: "/commit/")
            if subject.type != "Release", let u = URL(string: html) { return u }
        }
        return URL(string: "https://github.com/\(repository.full_name)")!
    }
}
