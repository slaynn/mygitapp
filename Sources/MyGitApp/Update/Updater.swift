import AppKit
import Foundation
import Observation

/// `0.1.12` style versions, compared numerically (`0.1.10` > `0.1.9`, `0.1` == `0.1.0`).
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        parts = trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

struct GHRelease: Decodable {
    struct Asset: Decodable {
        var name: String
        var url: URL
    }
    var tag_name: String
    var assets: [Asset]
}

/// Self-update from the repo's GitHub releases.
///
/// The new version is downloaded and verified in the background, then swapped in either on
/// "Redémarrer" or when the app quits. Files written by URLSession in a non-sandboxed app carry no
/// quarantine flag, so Gatekeeper never prompts. Only the copy installed in an Applications folder
/// updates itself; dev builds from `build/` are left alone.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let repo = "slaynn/mygitapp"
    private static let checkInterval: TimeInterval = 4 * 3600

    enum State: Equatable {
        case idle
        case checking
        case downloading(String)
        case ready(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date?
    private var staged: URL?
    private var installStarted = false

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    /// The bundle to replace, or nil when updates don't apply (dev build, `swift run`).
    var installURL: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        if ProcessInfo.processInfo.environment["MYGITAPP_UPDATE_ANYWHERE"] == "1" { return url }
        let roots = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/"]
        return roots.contains { url.path.hasPrefix($0) } ? url : nil
    }

    var isEnabled: Bool { installURL != nil }

    func checkIfDue(_ client: GitHubClient?) {
        guard let client, isEnabled else { return }
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < Self.checkInterval { return }
        Task { await check(client, manual: false) }
    }

    func check(_ client: GitHubClient?, manual: Bool) async {
        guard let client else { return }
        guard isEnabled else {
            if manual { alert("Mises à jour désactivées", "Seule l'app installée dans Applications se met à jour (build de développement).") }
            return
        }
        switch state {
        case .checking, .downloading: return
        case .ready(let version):
            if manual { alert("Mise à jour prête", "La version \(version) est téléchargée : redémarre l'app pour l'installer.") }
            return
        default: break
        }

        state = .checking
        lastCheck = .now
        do {
            let release: GHRelease = try await client.rest("repos/\(Self.repo)/releases/latest")
            let latest = AppVersion(release.tag_name)
            guard latest > AppVersion(currentVersion),
                  let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                state = .idle
                if manual { alert("MyGitApp est à jour", "Version \(currentVersion).") }
                return
            }
            state = .downloading(latest.description)
            let zip = try await client.downloadAsset(asset.url)
            let version = latest.description
            staged = try await Task.detached(priority: .utility) { try Self.extract(zip, expecting: version) }.value
            state = .ready(version)
            // Dev-only: lets an end-to-end test exercise the swap without clicking.
            if ProcessInfo.processInfo.environment["MYGITAPP_UPDATE_AUTOINSTALL"] == "1" { installAndRelaunch() }
        } catch {
            state = .failed(error.localizedDescription)
            if manual { alert("Échec de la mise à jour", error.localizedDescription) }
        }
    }

    /// Unzips into ~/Library/Caches and checks the version and the code signature.
    nonisolated private static func extract(_ zip: URL, expecting version: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGitApp/Updates/\(version)", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: zip) }

        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) != nil else {
            throw UpdateError("Impossible d'extraire l'archive.")
        }
        let app = dir.appendingPathComponent("MyGitApp.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let found = info?["CFBundleShortVersionString"] as? String, AppVersion(found) == AppVersion(version) else {
            throw UpdateError("L'archive ne contient pas la version \(version).")
        }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) != nil else {
            throw UpdateError("La signature de la nouvelle version est invalide.")
        }
        return app
    }

    func installAndRelaunch() {
        install(relaunch: true)
        NSApp.terminate(nil)
    }

    /// Called from `applicationWillTerminate`: a downloaded update is applied on quit.
    func installOnQuit() {
        install(relaunch: false)
    }

    /// Hands the swap to a detached script that waits for this process to exit.
    private func install(relaunch: Bool) {
        guard case .ready = state, let staged, let destination = installURL, !installStarted else { return }
        installStarted = true
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("mygitapp-update-\(UUID().uuidString).sh")
        do {
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)",
                                 staged.path, destination.path, relaunch ? "1" : "0"]
            try process.run()
        } catch {
            installStarted = false
            state = .failed(error.localizedDescription)
        }
    }

    private static let installScript = """
    #!/bin/bash
    # args: <pid> <new .app> <installed .app> <relaunch 0|1>
    PID="$1"; NEW="$2"; DEST="$3"; RELAUNCH="$4"
    for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    BACKUP="$DEST.previous"
    rm -rf "$BACKUP"
    if mv "$DEST" "$BACKUP" && ditto "$NEW" "$DEST"; then
      rm -rf "$BACKUP" "$(dirname "$NEW")"
    else
      rm -rf "$DEST"; mv "$BACKUP" "$DEST"
    fi
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    [ "$RELAUNCH" = "1" ] && open "$DEST"
    rm -f "$0"
    """

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
