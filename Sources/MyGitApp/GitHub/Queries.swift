import Foundation

/// GraphQL documents. One query per screen.
enum Queries {
    static let prSummaryFragment = """
    fragment PRSummary on PullRequest {
      id number title url state isDraft createdAt updatedAt
      author { login avatarUrl }
      repository { nameWithOwner }
      headRefName baseRefName additions deletions reviewDecision
      comments { totalCount }
      reviewThreads(first: 100) { nodes { isResolved } }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    static let viewer = """
    query { viewer { login name avatarUrl } }
    """

    static let viewerRepositories = """
    query($after: String) {
      viewer {
        repositories(first: 100, after: $after,
                     affiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR],
                     ownerAffiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR],
                     orderBy: { field: PUSHED_AT, direction: DESC }) {
          pageInfo { hasNextPage endCursor }
          nodes {
            nameWithOwner description isPrivate isArchived isFork stargazerCount pushedAt
            owner { login avatarUrl }
          }
        }
      }
    }
    """

    static let repoOverview = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        id nameWithOwner name description url homepageUrl isPrivate isFork isArchived
        stargazerCount forkCount viewerHasStarred pushedAt updatedAt sshUrl
        owner { login avatarUrl }
        licenseInfo { spdxId name }
        primaryLanguage { name color }
        languages(first: 10, orderBy: { field: SIZE, direction: DESC }) {
          totalSize
          edges { size node { name color } }
        }
        repositoryTopics(first: 12) { nodes { topic { name } } }
        defaultBranchRef {
          name
          target {
            ... on Commit {
              history(first: 10) {
                nodes {
                  oid abbreviatedOid messageHeadline committedDate url
                  author { name avatarUrl user { login } }
                  statusCheckRollup { state }
                }
              }
            }
          }
        }
        latestRelease { tagName name publishedAt url }
        releases { totalCount }
        pullRequests(states: OPEN, first: 30, orderBy: { field: UPDATED_AT, direction: DESC }) {
          totalCount
          nodes { ...PRSummary }
        }
      }
    }
    """ + prSummaryFragment

    static let stargazers = """
    query($owner: String!, $name: String!, $after: String) {
      repository(owner: $owner, name: $name) {
        stargazers(first: 100, after: $after, orderBy: { field: STARRED_AT, direction: DESC }) {
          pageInfo { hasNextPage endCursor }
          edges { starredAt }
        }
      }
    }
    """

    static let pullRequestDetail = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          ...PRSummary
          body headRefOid changedFiles mergeable mergeStateStatus viewerDidAuthor merged
          viewerCanUpdate
          repository { nameWithOwner mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed }
          reviewRequests(first: 10) {
            nodes { requestedReviewer { __typename ... on User { login avatarUrl } ... on Team { name } ... on Bot { login avatarUrl } } }
          }
          reviews(first: 100) {
            nodes { id author { login avatarUrl } state body submittedAt createdAt url }
          }
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line originalLine startLine originalStartLine diffSide
              viewerCanResolve viewerCanUnresolve viewerCanReply
              resolvedBy { login }
              comments(first: 60) {
                nodes {
                  id author { login avatarUrl } body createdAt url diffHunk outdated
                  pullRequestReview { id }
                }
              }
            }
          }
          timelineItems(first: 100, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT,
                                                 MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT]) {
            nodes {
              __typename
              ... on IssueComment { id author { login avatarUrl } body createdAt url }
              ... on PullRequestCommit {
                id
                commit {
                  oid abbreviatedOid messageHeadline committedDate url
                  author { name avatarUrl user { login } }
                  statusCheckRollup { state }
                }
              }
              ... on HeadRefForcePushedEvent { id createdAt actor { login avatarUrl } beforeCommit { abbreviatedOid } afterCommit { abbreviatedOid } }
              ... on MergedEvent { id createdAt actor { login avatarUrl } }
              ... on ClosedEvent { id createdAt actor { login avatarUrl } }
              ... on ReopenedEvent { id createdAt actor { login avatarUrl } }
              ... on ReadyForReviewEvent { id createdAt actor { login avatarUrl } }
            }
          }
          lastCommit: commits(last: 1) {
            nodes {
              commit {
                oid
                statusCheckRollup {
                  state
                  contexts(first: 100) {
                    nodes {
                      __typename
                      ... on CheckRun {
                        name status conclusion detailsUrl startedAt completedAt
                        checkSuite { workflowRun { workflow { name } } }
                      }
                      ... on StatusContext { context state description targetUrl createdAt }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """ + prSummaryFragment

    static let searchPullRequests = """
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 100) {
        issueCount
        nodes { ...PRSummary }
      }
    }
    """ + prSummaryFragment

    /// Builds an aliased query fetching sidebar info for many repos at once.
    static func repoSummaries(_ repos: [String]) -> String {
        var body = ""
        for (i, full) in repos.enumerated() {
            let parts = full.split(separator: "/")
            guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isSafeRepoChar) }) else { continue }
            body += """
            r\(i): repository(owner: "\(parts[0])", name: "\(parts[1])") {
              nameWithOwner stargazerCount owner { avatarUrl } pullRequests(states: OPEN) { totalCount }
            }

            """
        }
        return "query {\n\(body)}"
    }

    // MARK: Mutations

    static let addReply = """
    mutation($thread: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $thread, body: $body }) { comment { id } }
    }
    """

    static let resolveThread = """
    mutation($thread: ID!) { resolveReviewThread(input: { threadId: $thread }) { thread { id isResolved } } }
    """

    static let unresolveThread = """
    mutation($thread: ID!) { unresolveReviewThread(input: { threadId: $thread }) { thread { id isResolved } } }
    """

    static let addComment = """
    mutation($subject: ID!, $body: String!) { addComment(input: { subjectId: $subject, body: $body }) { clientMutationId } }
    """

    static let approve = """
    mutation($pr: ID!, $body: String) {
      addPullRequestReview(input: { pullRequestId: $pr, event: APPROVE, body: $body }) { pullRequestReview { id } }
    }
    """

    static let merge = """
    mutation($pr: ID!, $method: PullRequestMergeMethod!) {
      mergePullRequest(input: { pullRequestId: $pr, mergeMethod: $method }) { pullRequest { id merged } }
    }
    """

    /// What the "new pull request" form needs: branches (most recent first) with their open PR, and the PR template.
    static let newPullRequestContext = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        id
        defaultBranchRef { name }
        pullRequestTemplates { body }
        refs(refPrefix: "refs/heads/", first: 100, orderBy: { field: TAG_COMMIT_DATE, direction: DESC }) {
          nodes {
            name
            target { ... on Commit { committedDate messageHeadline author { user { login } } } }
            associatedPullRequests(first: 1, orderBy: { field: CREATED_AT, direction: DESC }) { nodes { number state } }
          }
        }
      }
    }
    """

    static let createPullRequest = """
    mutation($repo: ID!, $base: String!, $head: String!, $title: String!, $body: String, $draft: Boolean) {
      createPullRequest(input: { repositoryId: $repo, baseRefName: $base, headRefName: $head,
                                 title: $title, body: $body, draft: $draft }) {
        pullRequest { number }
      }
    }
    """

    static let addStar = """
    mutation($id: ID!) { addStar(input: { starrableId: $id }) { starrable { stargazerCount } } }
    """

    static let removeStar = """
    mutation($id: ID!) { removeStar(input: { starrableId: $id }) { starrable { stargazerCount } } }
    """
}

private extension Character {
    var isSafeRepoChar: Bool { isLetter || isNumber || self == "-" || self == "_" || self == "." }
}
