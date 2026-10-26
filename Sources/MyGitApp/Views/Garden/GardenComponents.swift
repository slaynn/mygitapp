import GitGardenerCore
import SwiftUI

extension SafetyVerdict {
    var label: String {
        switch self {
        case .safe: "Sûre"
        case .review: "À vérifier"
        case .risky: "Risquée"
        case .blocked: "Bloquée"
        }
    }

    var pluralLabel: String {
        switch self {
        case .safe: "Sûres"
        case .review: "À vérifier"
        case .risky: "Risquées"
        case .blocked: "Bloquées"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .review: "exclamationmark.triangle.fill"
        case .risky: "xmark.octagon.fill"
        case .blocked: "lock.fill"
        }
    }

    var color: Color {
        switch self {
        case .safe: Theme.green
        case .review: Theme.orange
        case .risky: Theme.red
        case .blocked: Theme.gray
        }
    }
}

extension BranchAnalyzer.BlockReason {
    var label: String {
        switch self {
        case .protectedBranch: "branche protégée"
        case .checkedOutInMainFolder: "extraite dans le dossier principal"
        case .activeConductorWorkspace: "workspace Conductor actif"
        case .activeT3Thread: "thread T3 Code actif"
        }
    }
}

extension BranchAnalyzer.Report {
    /// The reasons a Blocked branch is blocked, nil for any other verdict.
    var blockReasonText: String? {
        blockReasons.isEmpty ? nil : blockReasons.map(\.label).joined(separator: ", ")
    }
}

extension BranchAnalyzer.PullRequest {
    var stateLabel: String {
        switch state {
        case "MERGED": "mergée"
        case "CLOSED": "fermée"
        case "OPEN": "ouverte"
        default: state.lowercased()
        }
    }

    var stateColor: Color {
        switch state {
        case "MERGED": Theme.purple
        case "CLOSED": Theme.red
        case "OPEN": Theme.green
        default: Theme.gray
        }
    }

    /// `https://github.com/o/r/pull/12`: the PR's own repo, which may be an upstream of the pinned one.
    var ref: PRRef? {
        let parts = url.pathComponents
        guard parts.count >= 5, parts[3] == "pull" else { return nil }
        return PRRef(owner: parts[1], name: parts[2], number: number)
    }
}

/// A small tinted capsule with an optional symbol.
struct GardenTag: View {
    let text: String
    var symbol: String?
    var color: Color = Theme.gray

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9)) }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

struct VerdictTag: View {
    let verdict: SafetyVerdict
    var reason: String?

    var body: some View {
        GardenTag(text: verdict.label, symbol: verdict.symbol, color: verdict.color)
            .help(reason ?? "")
    }
}

/// Safe, Review and Risky counts; zeros are left out.
struct VerdictCounts: View {
    let reports: [BranchAnalyzer.Report]

    var body: some View {
        HStack(spacing: 4) {
            ForEach([SafetyVerdict.safe, .review, .risky], id: \.self) { verdict in
                let count = reports.filter { $0.verdict == verdict }.count
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(verdict.color)
                        .background(verdict.color.opacity(0.16), in: Capsule())
                        .help("\(count) \(verdict.label.lowercased())")
                }
            }
        }
    }
}

struct LocationLabel: View {
    let location: Repo.BranchLocation

    var body: some View {
        switch location {
        case .localOnly:
            Label("Local uniquement", systemImage: "laptopcomputer")
        case .gone:
            Label("Origin supprimée", systemImage: "icloud.slash").foregroundStyle(Theme.orange)
        case .tracked(0, 0):
            Label("À jour", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
        case let .tracked(ahead, behind):
            Text("\(Image(systemName: "arrow.up"))\(ahead)  \(Image(systemName: "arrow.down"))\(behind)").monospacedDigit()
        }
    }
}

/// Info or error line above the repo cards.
struct GardenNotice: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct GardenBanner: View {
    let text: String
    let isError: Bool
    var onClose: (() -> Void)?

    var body: some View {
        let color = isError ? Theme.red : Theme.blue
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.octagon.fill" : "info.circle.fill").foregroundStyle(color)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.25)))
    }
}

extension Prerequisite {
    var message: String {
        switch self {
        case .gitMissing: "git est introuvable : installe les Command Line Tools avec « xcode-select --install », puis relance MyGitApp."
        case .githubMissing: "gh (GitHub CLI) n'est pas installé : les pull requests des branches ne sont pas affichées."
        case .githubSignedOut: "gh n'est pas connecté (« gh auth login ») : les pull requests des branches ne sont pas affichées."
        }
    }
}

extension URL {
    /// `~/code/app` rather than `/Users/me/code/app`.
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
