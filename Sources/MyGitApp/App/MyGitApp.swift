import AppKit
import SwiftUI

@main
struct MyGitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("MyGitApp") {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(app: app) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.installOnQuit() }
    }
}

struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Rechercher des mises à jour…") {
                Task { await Updater.shared.check(app.client, manual: true) }
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Rafraîchir") { app.refresh() }
                .keyboardShortcut("r")
        }
        CommandMenu("Aller") {
            Button("Rechercher un repo ou une PR…") { app.isCommandPaletteOpen = true }
                .keyboardShortcut("k")
            Button("Gérer les repos…") { app.isManageReposOpen = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Home") { app.selection = .home }
                .keyboardShortcut("0")
            Button("Inbox") { app.selection = .inbox }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Retour") { if !app.path.isEmpty { app.path.removeLast() } }
                .keyboardShortcut("[")
            Divider()
            ForEach(Array(app.store.ordered.prefix(9).enumerated()), id: \.element.id) { index, repo in
                Button(repo.nameWithOwner) { app.selection = .repo(repo.nameWithOwner) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.auth {
            case .loading:
                ProgressView("Connexion à GitHub…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsToken(let error):
                TokenEntryView(error: error)
            case .signedIn:
                MainView()
            }
        }
        .background(Theme.background)
        .task { await app.start() }
        .task(id: app.auth) {
            guard app.auth == .signedIn else { return }
            Updater.shared.checkIfDue(app.client)
            await DebugHooks.run(app)
        }
        .task {
            // Refresh the visible screen every minute while the app is frontmost.
            while !Task.isCancelled {
                if app.auth == .signedIn { Updater.shared.checkIfDue(app.client) }
                try? await Task.sleep(for: .seconds(60))
                if NSApp.isActive, app.auth == .signedIn { app.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard app.auth == .signedIn else { return }
            if let last = SyncClock.shared.lastSync, Date.now.timeIntervalSince(last) < 30 { return }
            app.refresh()
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            NavigationStack(path: $app.path) {
                rootDetail
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .pullRequest(let ref): PRDetailView(ref: ref)
                        case .repo(let name): RepoView(nameWithOwner: name)
                        }
                    }
            }
            .id(app.selection)
        }
        .sheet(isPresented: $app.isManageReposOpen) { ManageReposSheet() }
        .sheet(isPresented: $app.isCommandPaletteOpen) { CommandPalette() }
    }

    @ViewBuilder private var rootDetail: some View {
        switch app.selection ?? .home {
        case .home: HomeView()
        case .inbox: InboxView()
        case .pullRequests:
            PRSearchListView(title: "Mes pull requests", prs: app.visibleMyPRs,
                             empty: "Aucune PR ouverte de ta part sur tes repos épinglés.")
        case .reviewRequests:
            PRSearchListView(title: "Review requests", prs: app.visibleReviewRequests,
                             empty: "Personne n'attend ta review.")
        case .repo(let name): RepoView(nameWithOwner: name)
        }
    }
}

struct TokenEntryView: View {
    @Environment(AppState.self) private var app
    var error: String?
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connexion à GitHub").font(.title2.weight(.semibold))
            Text("L'app réutilise automatiquement la session de la CLI `gh`. Lance `gh auth login` dans un terminal puis relance l'app, ou colle un token personnel (scopes : repo, read:org, notifications).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("ghp_… ou github_pat_…", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let error { Text(error).foregroundStyle(Theme.red).font(.callout) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Se connecter", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty || busy)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        busy = true
        Task {
            await app.submitToken(token)
            busy = false
        }
    }
}
