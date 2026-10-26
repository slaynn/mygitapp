import Foundation

public struct Repo: Identifiable, Sendable {
    public var id: URL { path }
    public let path: URL
    public let name: String
    public let branches: [Branch]
    public let worktrees: [Worktree]
    public let originOnlyBranches: [String]

    public enum BranchLocation: Equatable, Sendable {
        case localOnly
        case tracked(ahead: Int, behind: Int)
        case gone
    }

    public struct Branch: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let location: BranchLocation
        public let lastCommitDate: Date
        public let worktreePath: URL?
        public let isCheckedOutInMainFolder: Bool
    }

    public struct Worktree: Sendable {
        public let path: URL
        public let branch: String?
        public let dirtyFileCount: Int
        public let lastActivity: Date
    }
}
