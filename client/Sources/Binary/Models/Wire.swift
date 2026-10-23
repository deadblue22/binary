import Foundation

// Types mirroring binaryd's JSON API (see docs/DESIGN.md).

struct ServerInfo: Decodable, Sendable {
    var name: String
    var hostname: String
    var os: String
    var arch: String
    var version: String
    var claudePath: String
    var claudeVersion: String
    var home: String
    var models: [ModelInfo]
    var effortLevels: [String]
    var permissionModes: [String]
    var defaultPermissionMode: String
    /// Newer servers: the account's plan usage as last read.
    var usage: PlanUsage?
}

/// The account's plan usage windows (5 hours, 7 days, per model), as Claude Code's /usage reports them.
struct PlanUsage: Codable, Hashable, Sendable {
    struct Window: Codable, Hashable, Sendable {
        var kind: String
        var percent: Double
        var resetsAt: String?
    }
    var available: Bool
    var windows: [Window]
    var at: String

    func window(_ kind: String) -> Window? { windows.first { $0.kind == kind } }
}

/// How full a session's context window was after its latest turn.
struct ContextUsage: Codable, Hashable, Sendable {
    var percent: Double
    var tokens: Int
    var max: Int
}

struct ModelInfo: Decodable, Hashable, Identifiable, Sendable {
    var value: String
    var displayName: String
    var description: String?
    var resolvedModel: String?
    var supportedEffortLevels: [String]?
    var id: String { value }
}

enum SessionState: String, Sendable {
    case idle, starting, running, waiting, error, external

    var label: String {
        switch self {
        case .idle: return tr("Idle")
        case .starting: return tr("Starting")
        case .running: return tr("Running")
        case .waiting: return tr("Waiting for approval")
        case .error: return tr("Error")
        case .external: return tr("Running elsewhere")
        }
    }

    var isBusy: Bool { self == .running || self == .starting || self == .waiting }
}

struct SessionSummary: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var cwd: String
    var project: String
    var gitBranch: String?
    var entrypoint: String?
    var createdAt: Date
    var updatedAt: Date
    var state: String
    var live: Bool
    var pid: Int?
    var activity: String?
    var lastSummary: String?
    var preview: String?
    var model: String?
    var effort: String?
    var permissionMode: String
    var lastModel: String?
    /// The effort Claude Code applied on the latest turn, after its own
    /// defaults and model limits: what Default came to.
    var appliedEffort: String?
    /// Newer servers: context window use after the latest turn Binary ran.
    var context: ContextUsage?
    /// Newer servers: background work of the live process (shells, subagents, monitors…).
    var tasks: [BackgroundTask]?
    /// Newer servers: when an idle live process gets closed by the idle timeout.
    var closesAt: Date?
    var pending: Int
    var costUsd: Double?
    var messages: Int
    var managed: Bool
    var error: String?
    // Newer servers only; older ones leave these out.
    var tag: String?
    var parentId: String?
    var subagentCount: Int?
    /// Worktree path when the session runs in one.
    var worktree: String?
    /// Set for sessions that ran over SSH from Claude desktop.
    var sshHost: String?
    /// False when the session's folder doesn't exist on the server's machine.
    var cwdExists: Bool?
    /// For state "external": which program also has the session open and
    /// whether a turn is running there (newer servers only).
    var external: ExternalHold?
    /// Messages waiting for the other program's turn to end; the server sends
    /// them in order (newer servers).
    var queued: [QueuedMessage]?

    var status: SessionState { SessionState(rawValue: state) ?? .idle }
    /// The group (tag) name, nil when ungrouped.
    var group: String? {
        guard let t = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Continues the session in a terminal on its machine.
    var resumeCommand: String { "cd \(shellQuote(cwd)) && claude --resume \(id)" }
}

func shellQuote(_ s: String) -> String {
    if s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-~".contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Another program has the session open.
struct ExternalHold: Codable, Hashable, Sendable {
    /// A turn is in progress there.
    var busy: Bool
    /// Only a background task (dev server, watcher) keeps it busy; the turn
    /// has ended, so it counts as idle.
    var background: Bool?
    /// "desktop", "tmux", "terminal", "ide" or "other".
    var holder: String

    /// A turn is running there right now: messages sent here wait for it.
    var working: Bool { busy && background != true }

    /// What it is doing there, for the info panel and tooltips.
    var activityName: String {
        if working { return tr("working") }
        return background == true ? tr("background task") : tr("idle")
    }

    var holderName: String {
        switch holder {
        case "desktop": return tr("the Claude desktop app")
        case "tmux": return "tmux"
        case "terminal": return tr("a terminal")
        case "ide": return tr("an IDE")
        default: return tr("another program")
        }
    }

    /// Short form for pills and the info panel.
    var shortName: String {
        switch holder {
        case "desktop": return tr("Claude desktop")
        case "tmux": return "tmux"
        case "terminal": return tr("Terminal")
        case "ide": return "IDE"
        default: return tr("another app")
        }
    }

    var icon: String {
        switch holder {
        case "desktop": return "macwindow"
        case "tmux": return "rectangle.split.3x1"
        case "terminal": return "terminal"
        case "ide": return "chevron.left.forwardslash.chevron.right"
        default: return "app.dashed"
        }
    }
}

extension SessionSummary {
    /// The state as shown: a session another program has open looks idle
    /// unless a turn is running there.
    var shownState: SessionState {
        guard status == .external, let x = external else { return status }
        return x.working ? .external : .idle
    }

    /// Held by another program (newer servers say which).
    var hold: ExternalHold? { status == .external ? external : nil }

    /// Status in words. A turn running elsewhere names the program.
    var statusText: String {
        guard let x = hold else { return status.label }
        return x.working ? tr("Working in \(x.shortName)") : SessionState.idle.label
    }

    /// "Held by Claude desktop · idle" for tooltips.
    var holdText: String? {
        hold.map { tr("Held by \($0.shortName) · \($0.activityName)") }
    }
}

/// A message the server holds until the other program's turn ends.
struct BackgroundTask: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// shell, subagent, monitor, workflow…
    var type: String
    var description: String
    var agentType: String?
    /// Housekeeping such as watchers: not activity.
    var ambient: Bool?
    var startedAt: Date?
}

extension SessionSummary {
    /// Background tasks that are real work, not housekeeping.
    var busyTasks: [BackgroundTask] { (tasks ?? []).filter { $0.ambient != true } }
}

struct QueuedMessage: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// Up to 200 characters of the message.
    var text: String?
    /// Number of images.
    var images: Int?
    var at: String?
}

/// A subagent run inside a session (GET /sessions/{id}/subagents).
struct SubagentInfo: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String?
    var entries: Int?
    var startedAt: Date?
    /// Last activity (newer servers); falls back to startedAt.
    var updatedAt: Date?
    /// The full prompt the subagent got (newer servers, up to 4000 chars).
    var prompt: String?
    /// Still working (newer servers).
    var running: Bool?
}

struct SubagentsResponse: Decodable { var subagents: [SubagentInfo] }
struct EntriesResponse: Decodable { var entries: [Entry] }

struct Block: Codable, Hashable, Sendable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var input: JSONValue?
    var toolUseId: String?
    var isError: Bool?
    var truncated: Bool?
    /// For user image blocks: key for GET /sessions/{id}/images/{key}.
    var image: String?
}

struct Entry: Codable, Identifiable, Hashable, Sendable {
    var seq: Int64
    var uuid: String
    var kind: String
    var time: String?
    var model: String?
    var messageId: String?
    var blocks: [Block]?
    var subtype: String?
    /// For subtype "app_event": the desktop event tag, e.g. "side-sessions-event".
    var event: String?
    var text: String?
    var isError: Bool?
    var costUsd: Double?
    var durationMs: Int64?
    var numTurns: Int?
    var id: String { uuid }
}

struct Partial: Decodable, Hashable, Sendable {
    var messageId: String
    var index: Int
    var type: String
    var name: String?
    var text: String?
    var size: Int
}

struct PermissionRequest: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var toolName: String
    var displayName: String?
    var title: String?
    var description: String?
    var input: JSONValue
    var suggestions: JSONValue?
    var blockedPath: String?
    var decisionReason: String?
    var toolUseId: String?
    var createdAt: Date
}

struct DirListing: Decodable, Sendable {
    var path: String
    var parent: String?
    var home: String
    var isGit: Bool?
    var entries: [DirEntry]
}

struct DirEntry: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var isGit: Bool?
    var id: String { path }
}

// MARK: - Event payloads

struct EventEnvelope: Decodable { var type: String }

struct SessionsEvent: Decodable { var sessions: [SessionSummary] }
struct SessionEvent: Decodable { var session: SessionSummary }
struct RemovedEvent: Decodable { var id: String }

struct SnapshotEvent: Decodable {
    var gen: String
    var entries: [Entry]
    var hasMore: Bool
    var session: SessionSummary
    var partial: Partial?
    var permissions: [PermissionRequest]
}

struct EntriesEvent: Decodable {
    var gen: String
    var entries: [Entry]
}

/// Sent instead of a snapshot when the client named (with `after=`) an entry
/// the server still has: only the entries after that anchor.
struct DeltaEvent: Decodable {
    var gen: String
    var anchor: String
    var anchorSeq: Int64
    var entries: [Entry]
    var session: SessionSummary
    var partial: Partial?
    var permissions: [PermissionRequest]
}

struct PartialEvent: Decodable { var partial: Partial? }
struct PermissionEvent: Decodable { var permission: PermissionRequest }
struct PermissionsEvent: Decodable { var permissions: [PermissionRequest] }
struct PermissionResolvedEvent: Decodable { var id: String }
struct NoticeEvent: Decodable { var level: String; var text: String }

struct EntriesPage: Decodable {
    var entries: [Entry]
    /// Missing when paging by uuid and the server doesn't know it.
    var hasMore: Bool?
    var gen: String?
}

struct UpdateResponse: Decodable {
    var session: SessionSummary
    var warnings: [String]?
}

// MARK: - Requests

struct CreateSessionRequest: Encodable {
    var cwd: String
    var prompt: String
    var model: String
    var effort: String
    var permissionMode: String
    var title: String
    /// Newer servers: start the session as a child of another one, in a group.
    var parentId: String?
    var tag: String?
    /// Branch to start on; with `worktree` a new worktree is cut from it.
    var branch: String?
    var worktree: Bool?
    var env: [String: String]?
    var images: [WireImage]?
}

/// An image sent with a message (base64 in JSON).
struct WireImage: Encodable, Sendable {
    var mediaType: String
    var data: String
}

/// GET /fs/git?path=…
struct GitInfo: Decodable, Sendable, Equatable {
    var isRepo: Bool
    var root: String?
    var current: String?
    var branches: [String]?
    var dirty: Bool?
    var worktrees: [GitWorktree]?
}

struct GitWorktree: Decodable, Sendable, Equatable {
    var path: String
    var branch: String?
}

/// Pinned and archived sessions and the group order, kept by newer servers
/// so every client shows the same (GET / PUT /layout, and the "layout"
/// event on the global stream). Each field is stamped with when a client
/// last changed it (ms); 0 means never.
struct SharedLayout: Codable, Equatable, Sendable {
    struct Stamps: Codable, Equatable, Sendable {
        var pinned: Double = 0
        var archived: Double = 0
        var groupOrder: Double = 0
    }
    var pinned: [String] = []
    var archived: [String] = []
    var groupOrder: [String] = []
    var at = Stamps()
}

/// PUT /layout: the fields to set, each with when it changed here.
struct LayoutUpdate: Encodable {
    var pinned: [String]?
    var archived: [String]?
    var groupOrder: [String]?
    var at: [String: Double] = [:]

    var isEmpty: Bool { pinned == nil && archived == nil && groupOrder == nil }
}

struct SettingsUpdate: Encodable {
    var model: String?
    var effort: String?
    var permissionMode: String?
    var title: String?
    /// Group name; "" removes the session from its group.
    var tag: String?
}

struct PermissionDecision: Encodable {
    var behavior: String
    var message: String?
    var updatedInput: JSONValue?
    var remember: Bool?
}

// MARK: - Dates

enum WireDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses Go's RFC 3339 output, which may carry up to nine fractional digits.
    static func parse(_ s: String) -> Date? {
        if let d = fractional.date(from: s) ?? plain.date(from: s) { return d }
        // Trim the fraction to milliseconds: 2026-10-20T04:42:31.123456789+08:00
        guard let dot = s.firstIndex(of: ".") else { return nil }
        var end = s.index(after: dot)
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        let digits = s[s.index(after: dot)..<end].prefix(3)
        let trimmed = String(s[..<dot]) + "." + digits + String(s[end...])
        return fractional.date(from: trimmed)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            return parse(s) ?? Date(timeIntervalSince1970: 0)
        }
        return d
    }()

    /// Writes dates the way the decoder reads them back (the local cache).
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(fractional.string(from: date))
        }
        return e
    }
}

/// A session whose messages match a search (GET /search, newer servers).
struct ContentHit: Codable, Hashable, Sendable {
    struct Snippet: Codable, Hashable, Sendable {
        /// The transcript entry the match is in.
        var uuid: String
        var role: String
        var time: Date?
        /// Text around the first match.
        var text: String
    }
    var id: String
    /// Messages that match.
    var hits: Int
    var snippets: [Snippet]
}
