import Foundation

enum GitHubError: LocalizedError {
    case unauthorized
    case rateLimited(reset: Date?)
    case http(Int, String)
    case graphQL([String])
    case notFound

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Token GitHub invalide ou expiré."
        case .rateLimited(let reset):
            "Limite d'API GitHub atteinte" + (reset.map { ", réessaie après \($0.formatted(date: .omitted, time: .shortened))" } ?? "") + "."
        case .http(let code, let message): "Erreur HTTP \(code) : \(message)"
        case .graphQL(let messages): messages.joined(separator: "\n")
        case .notFound: "Introuvable (repo supprimé ou accès refusé)."
        }
    }
}

extension JSONDecoder {
    static let github: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let github: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

/// Thin GitHub API client: GraphQL for screens, REST for files, notifications and contributors.
final class GitHubClient: @unchecked Sendable {
    let token: String
    private let session: URLSession
    private static let api = URL(string: "https://api.github.com")!

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    // MARK: GraphQL

    private struct GraphQLResponse<T: Decodable>: Decodable {
        struct Err: Decodable { var message: String; var type: String? }
        var data: T?
        var errors: [Err]?
    }

    /// Runs a query. Partial data is returned when present; errors are only thrown when
    /// the response carries no data at all.
    func graphql<T: Decodable>(_ query: String, _ variables: [String: Any?] = [:], as: T.Type = T.self) async throws -> T {
        var request = makeRequest(Self.api.appendingPathComponent("graphql"))
        request.httpMethod = "POST"
        let vars = variables.compactMapValues { $0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": vars])
        let data = try await send(request)
        let response = try JSONDecoder.github.decode(GraphQLResponse<T>.self, from: data)
        if let value = response.data { return value }
        let errors = response.errors ?? []
        if errors.contains(where: { $0.type == "NOT_FOUND" }) { throw GitHubError.notFound }
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw GitHubError.rateLimited(reset: nil) }
        throw GitHubError.graphQL(errors.map(\.message))
    }

    /// Mutations: any GraphQL error is surfaced.
    func mutate(_ query: String, _ variables: [String: Any?]) async throws {
        struct Empty: Decodable {}
        var request = makeRequest(Self.api.appendingPathComponent("graphql"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables.compactMapValues { $0 }])
        let data = try await send(request)
        let response = try JSONDecoder.github.decode(GraphQLResponse<Empty>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
    }

    /// Mutation whose payload is needed; any GraphQL error is surfaced.
    func mutate<T: Decodable>(_ query: String, _ variables: [String: Any?], as: T.Type) async throws -> T {
        var request = makeRequest(Self.api.appendingPathComponent("graphql"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables.compactMapValues { $0 }])
        let data = try await send(request)
        let response = try JSONDecoder.github.decode(GraphQLResponse<T>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
        guard let value = response.data else { throw GitHubError.graphQL(["Réponse vide de GitHub."]) }
        return value
    }

    // MARK: REST

    func rest<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        var components = URLComponents(url: Self.api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let data = try await send(makeRequest(components.url!))
        return try JSONDecoder.github.decode(T.self, from: data)
    }

    /// Downloads a release asset (works for private repos) to a temporary file.
    func downloadAsset(_ url: URL) async throws -> URL {
        var request = makeRequest(url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (temp, response) = try await session.download(for: request, delegate: StripAuthOnRedirect())
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GitHubError.http(http.statusCode, "téléchargement de \(url.lastPathComponent)")
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("MyGitApp-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    func restSend(_ method: String, _ path: String) async throws {
        var request = makeRequest(Self.api.appendingPathComponent(path))
        request.httpMethod = method
        _ = try await send(request)
    }

    // MARK: Plumbing

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MyGitApp", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw GitHubError.unauthorized
        case 403, 429:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.statusCode == 429 {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                throw GitHubError.rateLimited(reset: reset)
            }
            throw GitHubError.http(http.statusCode, Self.message(from: data))
        case 404: throw GitHubError.notFound
        default: throw GitHubError.http(http.statusCode, Self.message(from: data))
        }
    }

    private static func message(from data: Data) -> String {
        struct M: Decodable { var message: String }
        return (try? JSONDecoder().decode(M.self, from: data).message) ?? String(decoding: data.prefix(200), as: UTF8.self)
    }
}

/// Asset downloads redirect to a pre-signed storage URL that rejects a second credential.
private final class StripAuthOnRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var request = request
        if request.url?.host != task.originalRequest?.url?.host {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

// MARK: - Typed endpoints

extension GitHubClient {
    func viewer() async throws -> Viewer {
        struct R: Decodable { var viewer: Viewer }
        return try await graphql(Queries.viewer, as: R.self).viewer
    }

    func repoOverview(_ nameWithOwner: String) async throws -> RepoOverview {
        struct R: Decodable { var repository: RepoOverview? }
        let (owner, name) = try split(nameWithOwner)
        guard let repo = try await graphql(Queries.repoOverview, ["owner": owner, "name": name], as: R.self).repository else {
            throw GitHubError.notFound
        }
        return repo
    }

    /// Star timestamps within the last `days` days (newest first), capped at `maxPages` pages.
    func recentStars(_ nameWithOwner: String, days: Int = 30, maxPages: Int = 5) async throws -> [Date] {
        struct R: Decodable {
            struct Repo: Decodable {
                struct Conn: Decodable { struct Edge: Decodable { var starredAt: Date }; var pageInfo: PageInfo; var edges: [Edge] }
                var stargazers: Conn
            }
            var repository: Repo?
        }
        let (owner, name) = try split(nameWithOwner)
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        var dates: [Date] = []
        var cursor: String?
        for _ in 0..<maxPages {
            guard let conn = try await graphql(Queries.stargazers, ["owner": owner, "name": name, "after": cursor], as: R.self).repository?.stargazers else { break }
            let page = conn.edges.map(\.starredAt)
            dates += page.filter { $0 >= cutoff }
            if page.last.map({ $0 < cutoff }) ?? true || !conn.pageInfo.hasNextPage { break }
            cursor = conn.pageInfo.endCursor
        }
        return dates
    }

    func pullRequest(_ ref: PRRef) async throws -> PRDetail {
        struct R: Decodable { struct Repo: Decodable { var pullRequest: PRDetail? }; var repository: Repo? }
        let r = try await graphql(Queries.pullRequestDetail, ["owner": ref.owner, "name": ref.name, "number": ref.number], as: R.self)
        guard let pr = r.repository?.pullRequest else { throw GitHubError.notFound }
        return pr
    }

    func pullRequestFiles(_ ref: PRRef) async throws -> [PRFile] {
        var files: [PRFile] = []
        for page in 1...10 {
            let batch: [PRFile] = try await rest("repos/\(ref.owner)/\(ref.name)/pulls/\(ref.number)/files",
                                                 query: ["per_page": "100", "page": "\(page)"])
            files += batch
            if batch.count < 100 { break }
        }
        return files
    }

    func searchPullRequests(_ query: String) async throws -> [PRSummary] {
        struct R: Decodable { struct S: Decodable { var nodes: [PRSummary] }; var search: S }
        return try await graphql(Queries.searchPullRequests, ["q": query], as: R.self).search.nodes
    }

    func viewerRepositories(maxPages: Int = 10) async throws -> [RepoListItem] {
        struct R: Decodable {
            struct V: Decodable { struct Conn: Decodable { var pageInfo: PageInfo; var nodes: [RepoListItem] }; var repositories: Conn }
            var viewer: V
        }
        var repos: [RepoListItem] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let conn = try await graphql(Queries.viewerRepositories, ["after": cursor], as: R.self).viewer.repositories
            repos += conn.nodes
            guard conn.pageInfo.hasNextPage else { break }
            cursor = conn.pageInfo.endCursor
        }
        return repos
    }

    func repoSummaries(_ repos: [String]) async throws -> [String: RepoSummary] {
        guard !repos.isEmpty else { return [:] }
        let result = try await graphql(Queries.repoSummaries(repos), as: [String: RepoSummary?].self)
        var map: [String: RepoSummary] = [:]
        for summary in result.values.compactMap({ $0 }) { map[summary.nameWithOwner.lowercased()] = summary }
        return map
    }

    /// Loads up to `maxPages` × 100 branches, sorted by latest commit. `branchQuery` filters them by name on
    /// GitHub's side, to reach the ones past that limit.
    func newPullRequestContext(_ nameWithOwner: String, branchQuery: String? = nil, maxPages: Int = 10) async throws -> NewPRContext {
        struct R: Decodable {
            struct Repo: Decodable {
                struct Ref: Decodable {
                    struct Target: Decodable {
                        struct Author: Decodable { struct User: Decodable { var login: String }; var user: User? }
                        var committedDate: Date?
                        var messageHeadline: String?
                        var author: Author?
                    }
                    var name: String
                    var target: Target?
                }
                struct PR: Decodable { var number: Int; var state: String; var headRefName: String }
                struct PRs: Decodable { var nodes: [PR] }
                struct Template: Decodable { var body: String? }
                struct Default: Decodable { var name: String }
                struct Refs: Decodable { var pageInfo: PageInfo; var nodes: [Ref] }
                var id: String
                var defaultBranchRef: Default?
                var pullRequestTemplates: [Template]?
                var pullRequests: PRs?
                var refs: Refs?
            }
            var repository: Repo?
        }
        let (owner, name) = try split(nameWithOwner)
        var first: R.Repo?
        var refs: [R.Repo.Ref] = []
        var cursor: String?
        var isComplete = false
        for _ in 0..<maxPages {
            let variables: [String: Any?] = ["owner": owner, "name": name, "query": branchQuery, "after": cursor, "firstPage": cursor == nil]
            guard let page = try await graphql(Queries.newPullRequestContext, variables, as: R.self).repository else {
                throw GitHubError.notFound
            }
            first = first ?? page
            refs += page.refs?.nodes ?? []
            guard let info = page.refs?.pageInfo, info.hasNextPage else { isComplete = true; break }
            cursor = info.endCursor
        }
        guard let repo = first else { throw GitHubError.notFound }
        var latestPR: [String: R.Repo.PR] = [:] // newest first, so the first one seen per branch wins
        for pr in repo.pullRequests?.nodes ?? [] where latestPR[pr.headRefName] == nil { latestPR[pr.headRefName] = pr }
        let branches = refs.map { ref in
            let pr = latestPR[ref.name]
            return NewPRContext.Branch(name: ref.name, committedDate: ref.target?.committedDate, headline: ref.target?.messageHeadline,
                                       authorLogin: ref.target?.author?.user?.login,
                                       openPR: pr?.state == "OPEN" ? pr?.number : nil, hasPR: pr != nil)
        }
        .sorted { ($0.committedDate ?? .distantPast) > ($1.committedDate ?? .distantPast) }
        let template = repo.pullRequestTemplates?.lazy.compactMap(\.body).first { !$0.isEmpty }
        return NewPRContext(repositoryId: repo.id, defaultBranch: repo.defaultBranchRef?.name, template: template,
                            branches: branches, isComplete: isComplete)
    }

    func compare(_ nameWithOwner: String, base: String, head: String) async throws -> BranchComparison {
        try await rest("repos/\(nameWithOwner)/compare/\(base)...\(head)")
    }

    /// Returns the new PR's number.
    func createPullRequest(repositoryId: String, base: String, head: String, title: String, body: String, draft: Bool) async throws -> Int {
        struct R: Decodable { struct Payload: Decodable { struct PR: Decodable { var number: Int }; var pullRequest: PR }; var createPullRequest: Payload }
        let variables: [String: Any?] = ["repo": repositoryId, "base": base, "head": head, "title": title, "body": body, "draft": draft]
        return try await mutate(Queries.createPullRequest, variables, as: R.self).createPullRequest.pullRequest.number
    }

    func contributors(_ nameWithOwner: String) async throws -> [Contributor] {
        try await rest("repos/\(nameWithOwner)/contributors", query: ["per_page": "100"])
    }

    func notifications() async throws -> [GHNotification] {
        try await rest("notifications", query: ["per_page": "50"])
    }

    func markNotificationRead(_ id: String) async throws {
        try await restSend("PATCH", "notifications/threads/\(id)")
    }

    private func split(_ nameWithOwner: String) throws -> (String, String) {
        let parts = nameWithOwner.split(separator: "/")
        guard parts.count == 2 else { throw GitHubError.notFound }
        return (String(parts[0]), String(parts[1]))
    }
}
