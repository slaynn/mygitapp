import GitGardenerCore
import SwiftUI

/// Lists what a Prune will destroy, from verdicts recomputed after a fetch, before anything is deleted.
struct PruneConfirmationSheet: View {
    let targets: [Pruner.Target]
    let baseBranchOverrides: [String: [String]]
    let onFinish: ([Pruner.Outcome]) -> Void

    private struct Options: Hashable {
        var alsoOnOrigin = false
        var keepsBranch: Set<Pruner.Target.ID> = []
    }

    private struct Prepared {
        let options: Options
        let pruner: Pruner
        let plan: Pruner.Plan
    }

    @Environment(\.dismiss) private var dismiss
    @State private var options = Options()
    @State private var prepared: Prepared?
    @State private var errorMessage: String?
    @State private var typedConfirmation = ""
    @State private var isRunning = false

    /// Only a plan built from the options currently on screen can be confirmed.
    private var plan: Pruner.Plan? {
        prepared.flatMap { $0.options == options ? $0.plan : nil }
    }

    private var canConfirm: Bool {
        guard let plan, !plan.items.isEmpty, !isRunning else { return false }
        return !plan.requiresTypedConfirmation || typedConfirmation == "supprimer"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)
            content
                .padding(.horizontal, 24)
            Divider().padding(.top, 16)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 580, minHeight: 440)
        .background(Theme.panel)
        .interactiveDismissDisabled(isRunning)
        .task(id: options) { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Supprimer \(plan?.items.count ?? targets.count) éléments").font(.title2.bold())
                Text("Vérifie la sélection avant de confirmer.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let plan {
                    list(plan)
                } else if errorMessage == nil {
                    ProgressView("Analyse en cours…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
            }
            Toggle("Supprimer aussi sur origin", isOn: $options.alsoOnOrigin).disabled(isRunning)
            if plan?.requiresTypedConfirmation == true {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Cette suppression contient des éléments risqués ou touche origin.", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(Theme.red)
                    TextField("Tape « supprimer » pour confirmer", text: $typedConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isRunning)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Annuler") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunning)
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button("Supprimer", role: .destructive, action: confirm)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
        }
        .controlSize(.large)
    }

    private func list(_ plan: Pruner.Plan) -> some View {
        List {
            if !plan.changedVerdicts.isEmpty {
                Section("Verdicts modifiés") {
                    ForEach(plan.changedVerdicts, id: \.target.id) {
                        Text("\($0.target.name) (\($0.target.repoName)) : \($0.target.verdict.label) → \($0.verdict.label)")
                    }
                }
            }
            if !plan.skipped.isEmpty {
                Section("Ignorés") {
                    ForEach(plan.skipped, id: \.target.id) {
                        Text("\($0.target.name) (\($0.target.repoName)) : \($0.reason.label)").foregroundStyle(.secondary)
                    }
                }
            }
            section("Risquées", plan.items.filter { $0.verdict == .risky }, color: Theme.red)
            section("Sélection", plan.items.filter { $0.verdict != .risky }, color: .primary)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.inset)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Pruner.Plan.Item], color: Color) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.target.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.target.name).font(Theme.mono).foregroundStyle(color)
                            Text(item.target.repoName).foregroundStyle(.secondary)
                            if item.target.isOriginOnly {
                                Text("(origin uniquement)")
                            } else if item.deletesOnOrigin {
                                Text("(et sur origin)").foregroundStyle(Theme.red)
                            }
                            Spacer()
                            if item.target.worktreePath != nil {
                                Toggle("Garder la branche", isOn: keepsBranch(item.target)).toggleStyle(.checkbox).disabled(isRunning)
                            }
                        }
                        worktreeDetails(item)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// What removing the Worktree folder destroys beyond the branch.
    @ViewBuilder
    private func worktreeDetails(_ item: Pruner.Plan.Item) -> some View {
        if let worktree = item.target.worktreePath {
            Text("Supprime le dossier \(worktree.abbreviatedPath)").font(.caption).foregroundStyle(.secondary)
            if item.dirtyFileCount > 0 {
                Text("\(item.dirtyFileCount) fichiers non commités seront perdus").font(.caption).foregroundStyle(Theme.red)
            }
            if !item.ignoredFiles.isEmpty {
                let shown = item.ignoredFiles.prefix(5).joined(separator: ", ")
                Text("Fichiers ignorés supprimés aussi : \(shown)\(item.ignoredFiles.count > 5 ? "…" : "")")
                    .font(.caption).foregroundStyle(Theme.orange)
            }
        }
    }

    private func keepsBranch(_ target: Pruner.Target) -> Binding<Bool> {
        Binding(
            get: { options.keepsBranch.contains(target.id) },
            set: { keeps in
                if keeps { options.keepsBranch.insert(target.id) } else { options.keepsBranch.remove(target.id) }
            }
        )
    }

    private func load() async {
        // A confirmation typed for a previous plan must not approve a different one.
        typedConfirmation = ""
        errorMessage = nil
        let requested = options
        let current = targets.map { target -> Pruner.Target in
            var target = target
            target.keepsBranch = requested.keepsBranch.contains(target.id)
            return target
        }
        let overrides = baseBranchOverrides
        do {
            let result = try await Task.detached {
                // Same Base Branches as the list, so the fresh verdicts are comparable.
                let pruner = Pruner(analyzer: BranchAnalyzer(baseBranchOverrides: overrides), log: PruneLog())
                return Prepared(options: requested, pruner: pruner, plan: try await pruner.prepare(current, alsoOnOrigin: requested.alsoOnOrigin))
            }.value
            guard !Task.isCancelled else { return }
            prepared = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "\(error)"
        }
    }

    private func confirm() {
        guard canConfirm, let prepared, let plan else { return }
        isRunning = true
        Task {
            let outcomes = await prepared.pruner.execute(plan)
            onFinish(outcomes)
            dismiss()
        }
    }
}

extension Pruner.Target {
    var name: String { branch ?? worktreePath?.lastPathComponent ?? "" }
    var repoName: String { repoPath.lastPathComponent }
}

private extension Pruner.Plan.Skipped.Reason {
    var label: String {
        switch self {
        case .blocked: "désormais bloquée"
        case .changed: "a changé depuis la sélection, réanalyse"
        }
    }
}
