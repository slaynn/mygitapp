import Foundation
import Testing
@testable import GitGardenerCore

@Suite struct RepoLocatorTests {
    private let tmp: URL

    init() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gg-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    private func initRepo(_ relativePath: String) throws -> URL {
        let path = tmp.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let git = Git(path: path)
        try git.run("init", "-b", "main")
        try git.run("-c", "user.name=T", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init")
        return path
    }

    @Test func aRepoIsItself() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try initRepo("repo")
        #expect(RepoLocator.locate(repo) == .repo(repo))
    }

    @Test func aWorktreeLeadsToItsRepo() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try initRepo("repo")
        let worktree = tmp.appendingPathComponent("elsewhere/wt")
        try Git(path: repo).run("worktree", "add", "-b", "wt", worktree.path)

        #expect(RepoLocator.locate(worktree) == .worktree(of: repo))
    }

    @Test func aParentListsReposUpToThreeLevelsSkippingWorktreesAndDependencies() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let shallow = try initRepo("code/b")
        let deep = try initRepo("code/client/team/a")
        _ = try initRepo("code/one/two/three/too-deep")
        _ = try initRepo("code/b2/node_modules/dep")
        try Git(path: shallow).run("worktree", "add", "-b", "wt", tmp.appendingPathComponent("code/wt").path)

        #expect(RepoLocator.locate(tmp.appendingPathComponent("code")) == .parent(of: [shallow, deep]))
    }

    @Test func aFolderWithoutRepoIsNotGit() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let empty = tmp.appendingPathComponent("empty/inner")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(RepoLocator.locate(tmp.appendingPathComponent("empty")) == .notGit)
    }
}
