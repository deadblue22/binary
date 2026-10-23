import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ConnectionStatus: Equatable {
    case connecting
    case online
    case offline(String)
}

/// A live connection to one binaryd: server info plus the session list kept
/// current through the global event stream.
@MainActor
@Observable
final class ServerConnection: Identifiable {
    let config: ServerConfig
    let api: APIClient?
    nonisolated var id: UUID { config.id }

    private(set) var status: ConnectionStatus = .connecting
    private(set) var info: ServerInfo?
    /// The account's plan usage on this server (5-hour and weekly windows).
    private(set) var usage: PlanUsage?
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    private(set) var sessions: [String: SessionSummary] = [:] {
        didSet {
            let names = Set(sessions.values.compactMap(\.group))
            if names != groupNames { groupNames = names }
        }
    }
    /// All group names in use on this server. Kept with the sessions: every
    /// sidebar row's menu reads it, and rescanning per row made each sidebar
    /// rebuild quadratic in the number of sessions.
    private(set) var groupNames: Set<String> = []
    /// Subagent lists, loaded when a session is expanded or opened.
    private(set) var subagents: [String: [SubagentInfo]] = [:]
    /// False once the server answered a subagent request in a way that shows
    /// it predates that feature.
    private(set) var supportsSubagents = true

    /// Called when a session's state changes, for notifications.
    @ObservationIgnored var onTransition: ((ServerConnection, SessionSummary?, SessionSummary) -> Void)?
    /// Pinned, archived and group order as the server keeps them; nil until it
    /// sends them (older servers never do).
    @ObservationIgnored private(set) var layout: SharedLayout?
    /// Called with the server's layout on connecting and whenever it changes.
    @ObservationIgnored var onLayout: ((ServerConnection, SharedLayout) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The app is in the background (iOS), where the system cuts the stream:
    /// that isn't shown as offline, `resume()` connects again quietly.
    @ObservationIgnored var suspended = false

    init(config: ServerConfig) {
        self.config = config
        if let url = URL(string: config.url.trimmingCharacters(in: .whitespaces)), url.scheme != nil {
            api = APIClient(baseURL: url, token: config.token)
        } else {
            api = nil
            status = .offline(tr("Invalid URL"))
        }
        // The list as last seen, so the sidebar fills in before the server answers.
        if let saved = LocalCache.shared.sessions(server: config.id) {
            sessions = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            groupNames = Set(saved.compactMap(\.group))  // didSet doesn't run in init
        }
    }

    private func saveSessions() {
        LocalCache.shared.storeSessions(server: id, Array(sessions.values))
    }

    var displayName: String {
        config.name.isEmpty ? (info?.name ?? config.url) : config.name
    }

    func start() {
        guard let api, task == nil else { return }
        task = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let info: ServerInfo = try await api.get("/info")
                    self.info = info
                    if let u = info.usage { self.usage = u }
                    self.status = .online
                    self.usageTask?.cancel()
                    self.usageTask = Task { [weak self] in
                        // Plan usage moves slowly; the server caches it for a few minutes too.
                        while !Task.isCancelled {
                            await self?.refreshUsage()
                            try? await Task.sleep(nanoseconds: 300_000_000_000)
                        }
                    }
                    delay = 1
                    for try await data in api.events("/events") {
                        self.handle(data)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    if !self.suspended { self.status = .offline(error.localizedDescription) }
                }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 15)
            }
        }
    }

    /// Plan usage, read through GET /usage (the server caches it a few minutes).
    func refreshUsage(force: Bool = false) async {
        struct R: Decodable { var usage: PlanUsage? }
        if let r: R = try? await requireAPI().get("/usage", query: force ? ["refresh": "1"] : [:]), let u = r.usage { usage = u }
    }

    func stop() {
        usageTask?.cancel()
        usageTask = nil
        task?.cancel()
        task = nil
    }

    func reconnect() {
        stop()
        status = .connecting
        start()
    }

    /// Back from the background: connects again keeping the status shown, so
    /// the list doesn't blink offline and back. A failure still shows.
    func resume() {
        suspended = false
        stop()
        start()
    }

    private func handle(_ data: Data) {
        let dec = WireDate.decoder
        guard let env = try? dec.decode(EventEnvelope.self, from: data) else { return }
        switch env.type {
        case "sessions":
            guard let ev = try? dec.decode(SessionsEvent.self, from: data) else { return }
            sessions = Dictionary(ev.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            saveSessions()
        case "session":
            guard let ev = try? dec.decode(SessionEvent.self, from: data) else { return }
            upsert(ev.session)
        case "usage":
            struct UsageEvent: Decodable { var usage: PlanUsage }
            if let ev = try? dec.decode(UsageEvent.self, from: data) { usage = ev.usage }
        case "layout":
            struct LayoutEvent: Decodable { var layout: SharedLayout }
            if let ev = try? dec.decode(LayoutEvent.self, from: data) { received(ev.layout) }
        case "removed":
            guard let ev = try? dec.decode(RemovedEvent.self, from: data) else { return }
            sessions[ev.id] = nil
            saveSessions()
        default:
            break
        }
    }

    /// Applies a summary we received from any stream (global or per-session).
    func upsert(_ s: SessionSummary) {
        let old = sessions[s.id]
        if old == s { return }
        sessions[s.id] = s
        saveSessions()
        if old?.state != s.state || old?.pending != s.pending {
            onTransition?(self, old, s)
        }
    }

    private func received(_ l: SharedLayout) {
        layout = l
        onLayout?(self, l)
    }

    /// Sends layout changes made here (PUT /layout).
    func sendLayout(_ u: LayoutUpdate) async {
        struct R: Decodable { var layout: SharedLayout }
        guard let r: R = try? await requireAPI().send("PUT", "/layout", body: u), r.layout != layout else { return }
        received(r.layout)
    }

    var pendingCount: Int { sessions.values.reduce(0) { $0 + $1.pending } }

    /// Sessions started from the given session (by parentId).
    func children(of id: String) -> [SessionSummary] {
        sessions.values.filter { $0.parentId == id && $0.id != id }
    }

    // MARK: - API

    func requireAPI() throws -> APIClient {
        guard let api else { throw APIError(message: tr("Invalid server address")) }
        return api
    }

    /// The server runs on this Mac, so its folders can be opened in Finder.
    var isLocal: Bool {
        guard let host = URL(string: config.url)?.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Ends the session's Claude Code process (the session stays).
    func stop(_ id: String) async throws {
        let _: OK = try await requireAPI().post("/sessions/\(id)/stop")
    }

    /// Stops one background task of a live session.
    func stopTask(_ id: String, task: String) async throws {
        let _: OK = try await requireAPI().post("/sessions/\(id)/tasks/\(task)/stop")
    }

    /// PATCH /sessions/{id}; returns the updated summary.
    @discardableResult
    func update(_ id: String, _ u: SettingsUpdate) async throws -> SessionSummary {
        let r: UpdateResponse = try await requireAPI().send("PATCH", "/sessions/\(id)", body: u)
        upsert(r.session)
        return r.session
    }

    /// Moves sessions into a group ("" = out of any group).
    func setGroup(_ ids: [String], _ tag: String) async throws {
        for id in ids {
            let s = try await update(id, SettingsUpdate(tag: tag))
            let want = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if (s.group ?? "") != want {
                throw APIError(message: tr("This server doesn't support groups; it needs a newer binaryd with the tag field"))
            }
        }
    }

    func loadSubagents(_ id: String) async {
        guard supportsSubagents, let api else { return }
        do {
            let r: SubagentsResponse = try await api.get("/sessions/\(id)/subagents")
            // Newest first everywhere (the server lists them oldest first).
            let list = r.subagents.enumerated().sorted { a, b in
                switch (a.element.startedAt, b.element.startedAt) {
                case let (x?, y?) where x != y: return x > y
                default: return a.offset > b.offset
                }
            }.map(\.element)
            if subagents[id] != list { subagents[id] = list }
        } catch let e as APIError where e.status == 404 || e.status == 405 {
            // Older binaryd: no subagent API. A 404 for one session with a
            // newer server just means it has none.
            if sessions[id]?.subagentCount == nil { supportsSubagents = false }
            subagents[id] = []
        } catch {
            // Keep whatever we had; the row retries on its next refresh.
        }
    }

    /// Sessions whose folder turned out to be missing on this server (checked
    /// when opened, or learned from a failed send).
    private(set) var missingFolders: Set<String> = []

    /// Sessions Binary can show but not drive: they ran elsewhere (SSH) and
    /// their folder isn't on this machine.
    func isViewOnly(_ s: SessionSummary) -> Bool {
        s.sshHost != nil || s.cwdExists == false || missingFolders.contains(s.id)
    }

    func markFolderMissing(_ id: String) { missingFolders.insert(id) }

    /// Checks the folder once when the server doesn't say whether it exists.
    func checkFolder(_ s: SessionSummary) async {
        guard s.cwdExists == nil, s.sshHost == nil, !missingFolders.contains(s.id), !s.cwd.isEmpty else { return }
        do {
            let _: DirListing = try await requireAPI().get("/fs/dirs", query: ["path": s.cwd])
        } catch let e as APIError where e.status == 400 || e.status == 404 {
            // Only the server saying the folder is gone counts; a 404 for the
            // endpoint itself (older or other servers) doesn't.
            if e.message.contains("ENOENT") || e.message.localizedCaseInsensitiveContains("not exist")
                || e.message.localizedCaseInsensitiveContains("no such file") {
                missingFolders.insert(s.id)
            }
        } catch {}
    }

    /// Images in user messages, cached in memory and on disk (keys never
    /// change); nil when the server no longer has it.
    @ObservationIgnored private let imageCache = NSCache<NSString, PlatformImage>()
    @ObservationIgnored private var missingImages: Set<String> = []

    /// A file a message points at, from the server (relative to the session's folder).
    func file(session: String, path: String) async throws -> (Data, String) {
        try await requireAPI().file("/sessions/\(session)/file", query: ["path": path])
    }

    func image(session: String, key: String) async -> PlatformImage? {
        let k = "\(session)/\(key)" as NSString
        if let img = imageCache.object(forKey: k) { return img }
        if missingImages.contains(k as String) { return nil }
        if let data = LocalCache.shared.image(server: id, session: session, key: key), let img = PlatformImage(data: data) {
            imageCache.setObject(img, forKey: k, cost: data.count)
            return img
        }
        do {
            let data = try await requireAPI().data("/sessions/\(session)/images/\(key)")
            guard let img = PlatformImage(data: data) else { return nil }
            imageCache.setObject(img, forKey: k, cost: data.count)
            LocalCache.shared.storeImage(server: id, session: session, key: key, data)
            return img
        } catch let e as APIError where e.status == 404 {
            missingImages.insert(k as String)
            return nil
        } catch {
            return nil
        }
    }

    /// Image bytes as served, for "Open in Preview".
    func imageData(session: String, key: String) async -> Data? {
        if let data = LocalCache.shared.image(server: id, session: session, key: key) { return data }
        return try? await requireAPI().data("/sessions/\(session)/images/\(key)")
    }

    /// Sessions whose messages contain every word of `query`. Empty from
    /// servers without full-text search.
    func searchContent(_ query: String) async throws -> [ContentHit] {
        struct R: Decodable { var results: [ContentHit] }
        do {
            let r: R = try await requireAPI().get("/search", query: ["q": query, "limit": "200"])
            return r.results
        } catch let e as APIError where e.status == 404 {
            return []
        }
    }

    func gitInfo(_ path: String) async -> GitInfo? {
        try? await requireAPI().get("/fs/git", query: ["path": path])
    }

    func subagentEntries(_ id: String, agent: String) async throws -> [Entry] {
        let r: EntriesResponse = try await requireAPI().get("/sessions/\(id)/subagents/\(agent)/entries")
        return r.entries
    }

    func create(_ req: CreateSessionRequest) async throws -> SessionSummary {
        let s: SessionSummary = try await requireAPI().send("POST", "/sessions", body: req)
        upsert(s)
        return s
    }

    func listDirs(_ path: String, hidden: Bool = false) async throws -> DirListing {
        var q = ["path": path]
        if hidden { q["hidden"] = "1" }
        return try await requireAPI().get("/fs/dirs", query: q)
    }

    func recentDirs() async throws -> [String] {
        struct R: Decodable { var dirs: [String] }
        let r: R = try await requireAPI().get("/fs/recent")
        return r.dirs
    }

    func mkdir(_ path: String) async throws -> String {
        struct B: Encodable { var path: String }
        struct R: Decodable { var path: String }
        let r: R = try await requireAPI().send("POST", "/fs/mkdir", body: B(path: path))
        return r.path
    }

    /// Effort levels the given model supports (all levels when unknown).
    func effortLevels(for model: String?) -> [String] {
        let all = info?.effortLevels ?? ["low", "medium", "high", "xhigh", "max"]
        guard let model, !model.isEmpty,
              let m = info?.models.first(where: { $0.value == model || $0.resolvedModel == model }),
              let levels = m.supportedEffortLevels, !levels.isEmpty else { return all }
        return levels
    }
}
