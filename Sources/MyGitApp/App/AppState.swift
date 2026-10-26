import AppKit
import Foundation
import Observation

enum SidebarItem: Hashable {
    case home, inbox, pullRequests, reviewRequests, garden
    case repo(String)
}

enum Route: Hashable {
    case pullRequest(PRRef)
    case repo(String)
}

/// Opens the "new pull request" sheet, optionally on a given repo and head branch.
struct NewPRRequest: Identifiable, Hashable {
    var id = UUID()
    var repo: String?
    var head: String?
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
    let garden = GardenStore()
    /// Local clone shown alone on the local branches screen; nil shows them all.
    var gardenFocus: URL?

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
    /// Summaries seen in any list, so a PR screen can draw its header before its detail arrives.
    private(set) var knownSummaries: [String: PRSummary] = [:]
    var sidebarError: String?

    /// When false, global lists only show repos pinned in the sidebar.
    var showAllRepos = false

    var isCommandPaletteOpen = false
    var isManageReposOpen = false
    var newPullRequest: NewPRRequest?

    // MARK: Auth

    func start() async {
        guard auth == .loading else { return }
        reviewRequests = DiskCache.shared.read("global-review-requests") ?? []
        myPRs = DiskCache.shared.read("global-my-prs") ?? []
        notifications = DiskCache.shared.read("global-notifications") ?? []
        repoSummaries = DiskCache.shared.read("global-repo-summaries") ?? [:]
        viewer = DiskCache.shared.read("viewer")
        remember(reviewRequests + myPRs)

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
        remember(reviewRequests + myPRs)
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

    func filter(_ prs: [PRSummary]) -> [PRSummary] {
        showAllRepos ? prs : prs.filter { isPinned($0.repository.nameWithOwner) }
    }

    func summary(for nameWithOwner: String) -> RepoSummary? { repoSummaries[nameWithOwner.lowercased()] }

    func remember(_ prs: [PRSummary]) {
        for pr in prs where knownSummaries[pr.ref.id] != pr { knownSummaries[pr.ref.id] = pr }
    }

    // MARK: Navigation

    func open(_ ref: PRRef) { path.append(.pullRequest(ref)) }

    func openRepo(_ nameWithOwner: String) {
        if isPinned(nameWithOwner) {
            selection = .repo(store.repo(named: nameWithOwner)!.nameWithOwner)
        } else {
            path.append(.repo(nameWithOwner))
        }
    }

    /// Repo of the screen on display, if any.
    var currentRepo: String? {
        switch path.last {
        case .repo(let name): return name
        case .pullRequest(let ref): return ref.nameWithOwner
        case nil: break
        }
        if case .repo(let name) = selection { return name }
        return nil
    }

    /// Defaults to the repo on screen, then the first pinned repo.
    func startNewPullRequest(repo: String? = nil, head: String? = nil) {
        newPullRequest = NewPRRequest(repo: repo ?? currentRepo ?? store.ordered.first?.nameWithOwner, head: head)
    }

    /// Local branches screen, focused on one repo's clone when given.
    func openGarden(repo nameWithOwner: String? = nil) {
        gardenFocus = nameWithOwner.flatMap { name in
            garden.repos.first { $0.nameWithOwner.caseInsensitiveCompare(name) == .orderedSame }?.path
        }
        selection = .garden
    }

    func didCreatePullRequest(_ ref: PRRef) {
        open(ref)
        Task { await refreshSidebar() }
        refreshTick += 1
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
