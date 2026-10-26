import GitGardenerCore
import SwiftUI

/// Branches pruned in the last 30 days, restorable while their commits still exist.
struct PruneLogSheet: View {
    private struct Row: Identifiable {
        let entry: PruneLog.Entry
        let isRestorable: Bool
        var id: String { "\(entry.repoPath)|\(entry.branch)|\(entry.date.timeIntervalSince1970)" }
    }

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    private let log = PruneLog()
    @State private var rows: [Row]?
    @State private var errorMessage: String?
    @State private var pendingRestore: PruneLog.Entry?
    @State private var isRestoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Journal des suppressions").font(.title2.bold())
                    Text("Les branches supprimées sont gardées 30 jours et restaurables tant que leurs commits existent.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if isRestoring { ProgressView().controlSize(.small) }
            }
            if let errorMessage {
                GardenBanner(text: errorMessage, isError: true)
            }
            if let rows, rows.isEmpty {
                EmptyStateText(text: "Aucune branche supprimée ces 30 derniers jours.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Table(rows ?? []) {
                    TableColumn("Repo") { Text(URL(fileURLWithPath: $0.entry.repoPath).lastPathComponent) }
                    TableColumn("Branche") { Text($0.entry.branch).font(Theme.mono) }
                    TableColumn("Commit") { Text($0.entry.commit.prefix(7)).font(Theme.mono) }
                        .width(70)
                    TableColumn("Date") { Text($0.entry.date.formatted(date: .abbreviated, time: .shortened)) }
                    TableColumn("Aussi sur origin") { Text($0.entry.deletedOnOrigin ? "Oui" : "Non") }
                        .width(100)
                    TableColumn("") { row in
                        Button("Restaurer") { pendingRestore = row.entry }.disabled(!row.isRestorable || isRestoring)
                    }
                    .width(90)
                }
                .overlay { if rows == nil { ProgressView() } }
            }
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 440)
        .background(Theme.panel)
        .dismissOnOutsideClick(dismiss)
        .task { await reload() }
        .confirmationDialog(
            "Restaurer \(pendingRestore?.branch ?? "") ?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { entry in
            Button(entry.deletedOnOrigin ? "Restaurer et repousser sur origin" : "Restaurer") {
                Task { await restore(entry) }
            }
        } message: { entry in
            Text(entry.deletedOnOrigin
                ? "La branche sera recréée au commit \(entry.commit.prefix(7)) et repoussée sur origin."
                : "La branche sera recréée localement au commit \(entry.commit.prefix(7)).")
        }
    }

    private func reload() async {
        let log = log
        do {
            rows = try await Task.detached {
                try log.entries().sorted { $0.date > $1.date }.map { Row(entry: $0, isRestorable: log.isRestorable($0)) }
            }.value
        } catch {
            rows = []
            errorMessage = "\(error)"
        }
    }

    private func restore(_ entry: PruneLog.Entry) async {
        isRestoring = true
        defer { isRestoring = false }
        let log = log
        do {
            try await Task.detached { try log.restore(entry) }.value
            errorMessage = nil
            let path = RepoLocator.canonical(URL(fileURLWithPath: entry.repoPath))
            if app.garden.repo(at: path) != nil { Task { await app.garden.analyze([path]) } }
        } catch {
            errorMessage = "\(error)"
        }
        await reload()
    }
}
