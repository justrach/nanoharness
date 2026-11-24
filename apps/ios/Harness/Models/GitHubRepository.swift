// Read-only GitHub issue & PR browser models and client-side analytics engine.
// Mirrors crates/rpc/src/github_repository.rs (`BrowseCheckoutGitHub`) and the
// desktop dashboard rules in apps/nano/src/app_github_repository.zig &
// apps/nano/src/view_github_overview.zig.

import Foundation

// MARK: - Wire contracts (crates/rpc/src/github_repository.rs)

enum GitHubRepositoryKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case pulls
    case issues
    case pull
    case issue
    case files
    case activity

    var id: String { rawValue }

    var isList: Bool {
        self == .pulls || self == .issues
    }

    var isPull: Bool {
        self == .pulls || self == .pull
    }

    var detailKind: GitHubRepositoryKind {
        isPull ? .pull : .issue
    }
}

enum GitHubRepositoryState: String, CaseIterable, Codable, Identifiable, Sendable {
    case open
    case closed
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .all: return "All"
        }
    }
}

struct GitHubRepositoryIdentity: Decodable, Equatable, Sendable {
    let key: String
    let host: String
    let owner: String
    let name: String
    let url: String

    var fullName: String {
        owner.isEmpty ? name : "\(owner)/\(name)"
    }
}

struct GitHubRepositoryItem: Decodable, Equatable, Identifiable, Sendable {
    let number: UInt64
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let author: String
    let updatedAt: String
    let createdAt: String
    let labels: [String]

    var id: UInt64 { number }

    enum CodingKeys: String, CodingKey {
        case number, title, url, state, isDraft, author, updatedAt, createdAt, labels
    }

    init(
        number: UInt64,
        title: String,
        url: String,
        state: String,
        isDraft: Bool,
        author: String,
        updatedAt: String,
        createdAt: String = "",
        labels: [String] = []
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.author = author
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.labels = labels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(UInt64.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        state = try c.decode(String.self, forKey: .state)
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

struct GitHubRepositoryDetail: Decodable, Equatable, Sendable {
    let number: UInt64
    let title: String
    let url: String
    let state: String
    let body: String
    let author: String
    let createdAt: String
    let updatedAt: String
    let isDraft: Bool
    let baseRef: String?
    let headRef: String?
    let additions: UInt64?
    let deletions: UInt64?
    let changedFiles: UInt64?
    let labels: [String]

    enum CodingKeys: String, CodingKey {
        case number, title, url, state, body, author, createdAt, updatedAt, isDraft
        case baseRef, headRef, additions, deletions, changedFiles, labels
    }

    init(
        number: UInt64,
        title: String,
        url: String,
        state: String,
        body: String,
        author: String,
        createdAt: String,
        updatedAt: String,
        isDraft: Bool,
        baseRef: String? = nil,
        headRef: String? = nil,
        additions: UInt64? = nil,
        deletions: UInt64? = nil,
        changedFiles: UInt64? = nil,
        labels: [String] = []
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.body = body
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.baseRef = baseRef
        self.headRef = headRef
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.labels = labels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(UInt64.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        state = try c.decode(String.self, forKey: .state)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        baseRef = try c.decodeIfPresent(String.self, forKey: .baseRef)
        headRef = try c.decodeIfPresent(String.self, forKey: .headRef)
        additions = try c.decodeIfPresent(UInt64.self, forKey: .additions)
        deletions = try c.decodeIfPresent(UInt64.self, forKey: .deletions)
        changedFiles = try c.decodeIfPresent(UInt64.self, forKey: .changedFiles)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

struct GitHubRepositoryFile: Decodable, Equatable, Identifiable, Sendable {
    let filename: String
    let status: String
    let additions: UInt64
    let deletions: UInt64
    let patch: String?
    let previousFilename: String?
    let patchTruncated: Bool

    var id: String { filename }
}

struct GitHubRepositoryEvent: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let event: String
    let author: String
    let createdAt: String
    let body: String?
    let commitSha: String?
}

struct BrowseCheckoutGitHubResponse: Decodable, Equatable, Sendable {
    let repository: GitHubRepositoryIdentity
    let kind: GitHubRepositoryKind
    let items: [GitHubRepositoryItem]
    let detail: GitHubRepositoryDetail?
    let files: [GitHubRepositoryFile]
    let events: [GitHubRepositoryEvent]
    let page: Int
    let hasNextPage: Bool
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case repository, kind, items, detail, files, events, page, hasNextPage, truncated
    }

    init(
        repository: GitHubRepositoryIdentity,
        kind: GitHubRepositoryKind,
        items: [GitHubRepositoryItem] = [],
        detail: GitHubRepositoryDetail? = nil,
        files: [GitHubRepositoryFile] = [],
        events: [GitHubRepositoryEvent] = [],
        page: Int = 1,
        hasNextPage: Bool = false,
        truncated: Bool = false
    ) {
        self.repository = repository
        self.kind = kind
        self.items = items
        self.detail = detail
        self.files = files
        self.events = events
        self.page = page
        self.hasNextPage = hasNextPage
        self.truncated = truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repository = try c.decode(GitHubRepositoryIdentity.self, forKey: .repository)
        kind = try c.decode(GitHubRepositoryKind.self, forKey: .kind)
        items = try c.decodeIfPresent([GitHubRepositoryItem].self, forKey: .items) ?? []
        detail = try c.decodeIfPresent(GitHubRepositoryDetail.self, forKey: .detail)
        files = try c.decodeIfPresent([GitHubRepositoryFile].self, forKey: .files) ?? []
        events = try c.decodeIfPresent([GitHubRepositoryEvent].self, forKey: .events) ?? []
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 1
        hasNextPage = try c.decodeIfPresent(Bool.self, forKey: .hasNextPage) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

// MARK: - Analytics & Client-Side Filters

enum GitHubStateChip: String, CaseIterable, Equatable, Sendable {
    case all
    case open
    case closed
    case merged
    case draft
}

struct GitHubGroupBucket: Identifiable, Equatable, Sendable {
    let name: String
    var open: Int
    var resolved: Int

    var total: Int { open + resolved }
    var id: String { name }
}

struct GitHubDayBucket: Identifiable, Equatable, Sendable {
    let date: String
    var open: Int
    var resolved: Int

    var id: String { date }

    var shortLabel: String {
        guard date.count >= 10 else { return date }
        return String(date.dropFirst(5).prefix(5))
    }
}

struct GitHubOverviewStats: Equatable, Sendable {
    let total: Int
    let open: Int
    let draft: Int
    let openTotal: Int
    let closed: Int
    let merged: Int
    let resolved: Int
    let latestNumber: UInt64
    let contributorCount: Int
    let topAuthor: String
    let topAuthorCount: Int
    let isLabelGrouping: Bool
    let groups: [GitHubGroupBucket]
    let days: [GitHubDayBucket]

    var openPercent: Int {
        total > 0 ? (openTotal * 100) / total : 0
    }

    var resolvedPercent: Int {
        total > 0 ? (resolved * 100) / total : 0
    }

    static func compute(items: [GitHubRepositoryItem]) -> GitHubOverviewStats {
        var open = 0
        var draft = 0
        var closed = 0
        var merged = 0
        var latest: UInt64 = 0
        var authors: [String: (open: Int, resolved: Int, total: Int)] = [:]
        var labels: [String: (open: Int, resolved: Int, total: Int)] = [:]
        var daysByDate: [String: (open: Int, resolved: Int)] = [:]

        for item in items {
            if item.number > latest { latest = item.number }
            let lowerState = item.state.lowercased()
            let isOpen = lowerState == "open"
            let isResolved = lowerState == "closed" || lowerState == "merged"

            if isOpen && item.isDraft {
                draft += 1
            } else if isOpen {
                open += 1
            } else if lowerState == "merged" {
                merged += 1
            } else if lowerState == "closed" {
                closed += 1
            }

            let author = item.author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty {
                var entry = authors[author] ?? (0, 0, 0)
                if isOpen { entry.open += 1 } else if isResolved { entry.resolved += 1 }
                entry.total += 1
                authors[author] = entry
            }

            for rawLabel in item.labels {
                let lbl = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !lbl.isEmpty else { continue }
                var entry = labels[lbl] ?? (0, 0, 0)
                if isOpen { entry.open += 1 } else if isResolved { entry.resolved += 1 }
                entry.total += 1
                labels[lbl] = entry
            }

            if let day = dayPrefix(item.updatedAt) {
                var entry = daysByDate[day] ?? (0, 0)
                if isOpen { entry.open += 1 } else if isResolved { entry.resolved += 1 }
                daysByDate[day] = entry
            }
        }

        let top = authors.max { lhs, rhs in
            if lhs.value.total != rhs.value.total { return lhs.value.total < rhs.value.total }
            return lhs.key > rhs.key
        }

        let isLabelGrouping = !labels.isEmpty
        let rawMap = isLabelGrouping ? labels : authors
        let sortedGroups = rawMap
            .map { GitHubGroupBucket(name: $0.key, open: $0.value.open, resolved: $0.value.resolved) }
            .sorted { lhs, rhs in
                if lhs.total != rhs.total { return lhs.total > rhs.total }
                return lhs.name < rhs.name
            }
            .prefix(6)

        let sortedDays = daysByDate
            .map { GitHubDayBucket(date: $0.key, open: $0.value.open, resolved: $0.value.resolved) }
            .sorted { $0.date > $1.date }
            .prefix(6)
            .sorted { $0.date < $1.date }

        return GitHubOverviewStats(
            total: items.count,
            open: open,
            draft: draft,
            openTotal: open + draft,
            closed: closed,
            merged: merged,
            resolved: closed + merged,
            latestNumber: latest,
            contributorCount: authors.count,
            topAuthor: top?.key ?? "",
            topAuthorCount: top?.value.total ?? 0,
            isLabelGrouping: isLabelGrouping,
            groups: Array(sortedGroups),
            days: Array(sortedDays)
        )
    }

    static func dayPrefix(_ iso: String) -> String? {
        guard iso.count >= 10 else { return nil }
        let prefix = String(iso.prefix(10))
        let chars = Array(prefix)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return nil }
        return prefix
    }
}

struct GitHubClientFilter: Equatable, Sendable {
    var stateChip: GitHubStateChip = .all
    var label: String?
    var author: String?

    var isActive: Bool {
        stateChip != .all || label != nil || author != nil
    }

    mutating func toggleState(_ chip: GitHubStateChip) {
        stateChip = stateChip == chip ? .all : chip
    }

    mutating func toggleLabel(_ name: String) {
        label = label == name ? nil : name
        author = nil
    }

    mutating func toggleAuthor(_ name: String) {
        author = author == name ? nil : name
        label = nil
    }

    mutating func clear() {
        stateChip = .all
        label = nil
        author = nil
    }

    func matches(_ item: GitHubRepositoryItem) -> Bool {
        let lowerState = item.state.lowercased()
        switch stateChip {
        case .all:
            break
        case .open:
            guard lowerState == "open" && !item.isDraft else { return false }
        case .draft:
            guard lowerState == "open" && item.isDraft else { return false }
        case .closed:
            guard lowerState == "closed" else { return false }
        case .merged:
            guard lowerState == "merged" else { return false }
        }

        if let label {
            let trimmed = item.labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard trimmed.contains(label) else { return false }
        }

        if let author {
            let itemAuthor = item.author.trimmingCharacters(in: .whitespacesAndNewlines)
            guard itemAuthor == author else { return false }
        }

        return true
    }

    func summary(shown: Int, total: Int) -> String {
        let statePart: String
        switch stateChip {
        case .all: statePart = ""
        case .open: statePart = "state: open"
        case .closed: statePart = "state: closed"
        case .merged: statePart = "state: merged"
        case .draft: statePart = "state: draft"
        }

        if let label {
            return statePart.isEmpty
                ? "Showing \(shown) of \(total) (label: \(label))"
                : "Showing \(shown) of \(total) (\(statePart) · \(label))"
        }
        if let author {
            return statePart.isEmpty
                ? "Showing \(shown) of \(total) (@\(author))"
                : "Showing \(shown) of \(total) (\(statePart) · @\(author))"
        }
        return "Showing \(shown) of \(total) (\(statePart))"
    }
}

// MARK: - Relay RPC & AppModel Entry Point

extension WorkspaceStore {
    /// BrowseCheckoutGitHub over the chat host's relay (`crates/engine/src/github_repository.rs`).
    func browseCheckoutGitHub(
        chatId: String,
        deviceId: String,
        kind: GitHubRepositoryKind,
        state: GitHubRepositoryState? = nil,
        number: UInt64? = nil,
        page: Int? = nil,
        expectedRepository: String? = nil
    ) async throws -> BrowseCheckoutGitHubResponse {
        var params: [String: Any] = [
            "chatId": chatId,
            "kind": kind.rawValue,
        ]
        if let state { params["state"] = state.rawValue }
        if let number { params["number"] = number }
        if let page { params["page"] = page }
        if let expectedRepository, !expectedRepository.isEmpty {
            params["expectedRepository"] = expectedRepository
        }
        return try await relay(for: deviceId).call(
            method: "BrowseCheckoutGitHub",
            params: params,
            timeoutSeconds: 30
        )
    }
}

extension AppModel {
    func browseCheckoutGitHub(
        chat: Chat,
        kind: GitHubRepositoryKind,
        state: GitHubRepositoryState? = nil,
        number: UInt64? = nil,
        page: Int? = nil,
        expectedRepository: String? = nil
    ) async throws -> BrowseCheckoutGitHubResponse {
        if let demo {
            return demo.browseGitHub(kind: kind, state: state, number: number, page: page)
        }
        guard let workspace else { throw RelayError.notConnected }
        let targetDevice = sessionStore(for: chat)?.hostDeviceId ?? chat.deviceId
        return try await workspace.browseCheckoutGitHub(
            chatId: chat.id,
            deviceId: targetDevice,
            kind: kind,
            state: state,
            number: number,
            page: page,
            expectedRepository: expectedRepository
        )
    }
}
