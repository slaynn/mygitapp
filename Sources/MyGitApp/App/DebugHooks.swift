import AppKit

/// Dev-only automation, inert unless `MYGITAPP_SNAPSHOT` is set:
///   MYGITAPP_OPEN=owner/repo | owner/repo#12 | inbox | reviews | prs | manage | palette
///   MYGITAPP_TAB=conversation | threads | files | checks           PR tab
///   MYGITAPP_SNAPSHOT=/path/shot.png                               window capture, then quit
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment
    static var initialPRTab: String? { env["MYGITAPP_TAB"] }

    @MainActor
    static func run(_ app: AppState) async {
        guard let output = env["MYGITAPP_SNAPSHOT"] else { return }
        if let target = env["MYGITAPP_OPEN"] {
            switch target {
            case "inbox": app.selection = .inbox
            case "reviews": app.selection = .reviewRequests
            case "prs": app.selection = .pullRequests
            case "manage": app.isManageReposOpen = true
            case "palette": app.isCommandPaletteOpen = true
            default:
                let parts = target.split(separator: "#")
                let repo = String(parts[0])
                app.selection = app.isPinned(repo) ? .repo(app.store.repo(named: repo)!.nameWithOwner) : .home
                if parts.count == 2, let number = Int(parts[1]), let ref = PRRef(nameWithOwner: repo, number: number) {
                    try? await Task.sleep(for: .milliseconds(300))
                    app.open(ref)
                }
            }
        }
        try? await Task.sleep(for: .seconds(Double(env["MYGITAPP_DELAY"] ?? "") ?? 6))
        let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil })
        if let window = main?.attachedSheet ?? main,
           let view = window.contentView?.superview ?? window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
        exit(0) // terminate(nil) is refused while a sheet is open
    }
}
