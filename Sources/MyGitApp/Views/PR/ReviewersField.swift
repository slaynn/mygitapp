import AppKit
import SwiftUI

/// The PR's pending review requests, each removable, and a picker to ask someone else.
struct ReviewersField: View {
    @Environment(AppState.self) private var app
    var pr: PRDetail
    var model: PRDetailModel
    @State private var isOpen = DebugHooks.openReviewers

    private var requested: [PRDetailExtra.ReviewRequest.Reviewer] {
        pr.extra.reviewRequests.nodes.compactMap(\.requestedReviewer)
    }
    private var canEdit: Bool { pr.summary.state == "OPEN" }

    var body: some View {
        HStack(spacing: 6) {
            Text("Reviewers").foregroundStyle(.secondary)
            if requested.isEmpty {
                Text("aucune review demandée").foregroundStyle(.tertiary)
            }
            ForEach(requested, id: \.self) { reviewer in
                chip(reviewer)
            }
            if canEdit {
                Button { isOpen = true } label: {
                    Label("Demander une review", systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                    ReviewerSearchList(pr: pr, model: model)
                }
            }
            if model.busy.contains("reviewers") { ProgressView().controlSize(.mini) }
            Spacer()
        }
        .font(.system(size: 12))
    }

    private func chip(_ reviewer: PRDetailExtra.ReviewRequest.Reviewer) -> some View {
        HStack(spacing: 4) {
            if reviewer.isTeam {
                Image(systemName: "person.2.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Avatar(url: reviewer.avatarUrl, size: 14)
            }
            Text(reviewer.display).fontWeight(.medium)
            if canEdit {
                Button { Task { await model.removeReviewRequest(reviewer, app: app) } } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Retirer la demande de review")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.fill, in: Capsule())
        .help("Review demandée à \(reviewer.display)")
    }
}

/// Click, type to filter, ↑↓ to move, ↩ to toggle. Picking someone already requested withdraws the request.
private struct ReviewerSearchList: View {
    @Environment(AppState.self) private var app
    var pr: PRDetail
    var model: PRDetailModel

    @State private var query = ""
    @State private var remote: [ReviewerCandidate] = []
    @State private var searching = false
    @State private var highlighted = 0
    /// Pointer position at the last key: rows filtered under a still pointer must not steal the highlight.
    @State private var pointerAtKeyPress: NSPoint?

    private var loaded: ReviewerCandidates? { model.reviewers.value }

    /// Every space-separated term must appear in the login, slug or name.
    private var results: [ReviewerCandidate] {
        let terms = query.lowercased().split(separator: " ")
        let matches = { (c: ReviewerCandidate) in
            let text = "\(c.handle) \(c.name ?? "")".lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        let local = (loaded?.candidates ?? []).filter(matches)
        let known = Set(local.map(\.id))
        return local + remote.filter { !known.contains($0.id) && matches($0) }
    }

    private func isRequested(_ candidate: ReviewerCandidate) -> Bool {
        pr.extra.reviewRequests.nodes.contains { $0.requestedReviewer.map(candidate.matches) ?? false }
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                KeySearchField(text: $query, placeholder: "Rechercher une personne ou une équipe") { step in
                    pointerAtKeyPress = NSEvent.mouseLocation
                    highlighted = min(max(highlighted + step, 0), max(0, results.count - 1))
                } onSubmit: {
                    if results.indices.contains(highlighted) { toggle(results[highlighted]) }
                }
                if searching || model.reviewers.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(10)
            Divider()
            if let error = model.reviewers.error, loaded == nil {
                Text(error).font(.callout).foregroundStyle(.secondary).padding(20)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, candidate in
                                row(candidate, isHighlighted: index == highlighted)
                                    .onHover { inside in
                                        guard inside, NSEvent.mouseLocation != pointerAtKeyPress else { return }
                                        highlighted = index
                                    }
                            }
                            if results.isEmpty && loaded != nil && !searching {
                                Text(query.isEmpty ? "Personne d'autre n'a accès à ce repo."
                                                   : "Personne ne correspond à « \(query) ».")
                                    .font(.callout).foregroundStyle(.secondary).padding(20)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: highlighted) { _, index in
                        let results = self.results
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
            if let error = model.actionError {
                Divider()
                Text(error).font(.caption).foregroundStyle(Theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            } else if let loaded, !loaded.isComplete && query.isEmpty {
                Divider()
                Text("\(loaded.candidates.count) personnes chargées sur un plus grand nombre. Tape pour chercher parmi toutes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(width: 380, height: 400)
        .task { await model.loadReviewers(app) }
        .onChange(of: query) {
            pointerAtKeyPress = NSEvent.mouseLocation
            highlighted = 0
        }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard loaded?.isComplete == false, !text.isEmpty else { remote = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true
            let found = await model.searchReviewers(text, app: app)
            if !Task.isCancelled { remote = found }
            searching = false
        }
    }

    private func toggle(_ candidate: ReviewerCandidate) {
        guard !model.busy.contains("reviewers") else { return }
        if let reviewer = pr.extra.reviewRequests.nodes.lazy.compactMap(\.requestedReviewer).first(where: candidate.matches) {
            Task { await model.removeReviewRequest(reviewer, app: app) }
        } else {
            Task { await model.requestReview(from: candidate, app: app) }
        }
    }

    private func row(_ candidate: ReviewerCandidate, isHighlighted: Bool) -> some View {
        Button { toggle(candidate) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .opacity(isRequested(candidate) ? 1 : 0)
                if candidate.isTeam {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Avatar(url: candidate.avatarUrl, size: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.isTeam ? (candidate.name ?? candidate.handle) : candidate.handle)
                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if let subtitle = candidate.isTeam ? "\(pr.summary.ref.owner)/\(candidate.handle)" : candidate.name,
                       !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if candidate.isSuggested { Badge(text: "Suggéré", color: Theme.green) }
                if candidate.isTeam { Badge(text: "Équipe") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isHighlighted ? Theme.blue.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
