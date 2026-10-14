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

    // MARK: REST

    func rest<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        var components = URLComponents(url: Self.api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let data = try await send(makeRequest(components.url!))
        return try JSONDecoder.github.decode(T.self, from: data)
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
