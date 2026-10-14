import AppKit
import Foundation
import Observation

enum SidebarItem: Hashable {
    case home, inbox, pullRequests, reviewRequests
    case repo(String)
}

enum Route: Hashable {
    case pullRequest(PRRef)
    case repo(String)
}

@MainActor @Observable
final class AppState {
    enum AuthState: Equatable {
        case loading
        case signedIn
        case needsToken(error: String?)
    }

    var auth: AuthState = .loading
    var viewer: Viewer?
    private(set) var client: GitHubClient?
    let store = RepoStore()

    var selection: SidebarItem? = .home {
        didSet { if selection != oldValue { path = [] } }
    }
    var path: [Route] = []

    /// Bumped by ⌘R and the auto-refresh timer; screens reload when it changes.
    var refreshTick = 0

    var reviewRequests: [PRSummary] = []
    var myPRs: [PRSummary] = []
    var notifications: [GHNotification] = []
    var repoSummaries: [String: RepoSummary] = [:]
    var sidebarError: String?

    /// When false, global lists only show repos pinned in the sidebar.
    var showAllRepos = false

    var isCommandPaletteOpen = false
    var isManageReposOpen = false

    // MARK: Auth

    func start() async {
        guard auth == .loading else { return }
        reviewRequests = DiskCache.shared.read("global-review-requests") ?? []
        myPRs = DiskCache.shared.read("global-my-prs") ?? []
        notifications = DiskCache.shared.read("global-notifications") ?? []
        repoSummaries = DiskCache.shared.read("global-repo-summaries") ?? [:]
        viewer = DiskCache.shared.read("viewer")

        let ghToken = await Task.detached { Auth.tokenFromGH() }.value
        if let ghToken, await signIn(with: ghToken) { return }
        if let saved = Auth.savedToken(), await signIn(with: saved) { return }
        auth = .needsToken(error: nil)
    }

    func submitToken(_ token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if await signIn(with: token) {
            Auth.saveToken(token)
        } else {
            auth = .needsToken(error: "Ce token a été refusé par GitHub.")
        }
    }

    private func signIn(with token: String) async -> Bool {
        let client = GitHubClient(token: token)
        guard let viewer = try? await client.viewer() else { return false }
        self.viewer = viewer
        self.client = client
        DiskCache.shared.write(viewer, key: "viewer")
        auth = .signedIn
        await refreshSidebar()
        return true
    }

    // MARK: Refresh

    func refresh() {
        refreshTick += 1
        Task { await refreshSidebar() }
    }

    func refreshSidebar() async {
        guard let client else { return }
        let repos = store.pinned.map(\.nameWithOwner)
        async let rr = client.searchPullRequests("is:pr is:open archived:false review-requested:@me")
        async let mine = client.searchPullRequests("is:pr is:open archived:false author:@me")
        async let notifs = client.notifications()
        async let sums = client.repoSummaries(repos)

        var errors: [String] = []
        do { reviewRequests = try await rr; DiskCache.shared.write(reviewRequests, key: "global-review-requests") }
        catch { errors.append(error.localizedDescription) }
        do { myPRs = try await mine; DiskCache.shared.write(myPRs, key: "global-my-prs") }
        catch { errors.append(error.localizedDescription) }
        do { notifications = try await notifs; DiskCache.shared.write(notifications, key: "global-notifications") }
        catch { errors.append(error.localizedDescription) }
        do { repoSummaries = try await sums; DiskCache.shared.write(repoSummaries, key: "global-repo-summaries") }
        catch { errors.append(error.localizedDescription) }
        sidebarError = errors.first
        if errors.isEmpty { SyncClock.shared.markSynced() }
    }

    // MARK: Filtering

    func isPinned(_ nameWithOwner: String) -> Bool { store.pinnedNames.contains(nameWithOwner.lowercased()) }

    var visibleReviewRequests: [PRSummary] { filter(reviewRequests) }
    var visibleMyPRs: [PRSummary] { filter(myPRs) }
    var visibleNotifications: [GHNotification] {
        showAllRepos ? notifications : notifications.filter { isPinned($0.repository.full_name) }
    }

    private func filter(_ prs: [PRSummary]) -> [PRSummary] {
        showAllRepos ? prs : prs.filter { isPinned($0.repository.nameWithOwner) }
    }

    func summary(for nameWithOwner: String) -> RepoSummary? { repoSummaries[nameWithOwner.lowercased()] }

    // MARK: Navigation

    func open(_ ref: PRRef) { path.append(.pullRequest(ref)) }

    func openRepo(_ nameWithOwner: String) {
        if isPinned(nameWithOwner) {
            selection = .repo(store.repo(named: nameWithOwner)!.nameWithOwner)
        } else {
            path.append(.repo(nameWithOwner))
        }
    }

    func markRead(_ notification: GHNotification) {
        guard notification.unread, let index = notifications.firstIndex(where: { $0.id == notification.id }) else { return }
        notifications[index].unread = false
        Task { try? await client?.markNotificationRead(notification.id) }
    }

    func pinRepo(_ nameWithOwner: String, localPath: String? = nil) {
        store.add(nameWithOwner, localPath: localPath)
        Task { await refreshSidebar() }
    }
}
