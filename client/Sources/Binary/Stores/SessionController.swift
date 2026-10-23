import Foundation
import Observation

/// One rendered row of the transcript.
struct TranscriptItem: Identifiable, Hashable {
    enum Kind: Hashable {
        /// `images` holds each image's server key (nil when the server gave none).
        case user(text: String, images: [String?])
        case assistant(text: String)
        case thinking(text: String)
        case tool(use: Block, result: Block?)
        case system(subtype: String, text: String, isError: Bool, event: String?)
        case result(Entry)
    }
    var id: String
    var kind: Kind
    var time: String?
}

/// Live view of one session: transcript, streaming text, pending permission
/// requests, plus the actions a client can take on it.
@MainActor
@Observable
final class SessionController {
    let conn: ServerConnection
    let id: String

    private(set) var summary: SessionSummary?
    private(set) var entries: [Entry] = []
    private(set) var items: [TranscriptItem] = []
    private(set) var hasMore = false
    private(set) var partial: Partial?
    private(set) var permissions: [PermissionRequest] = []
    private(set) var loaded = false
    private(set) var connected = false
    private(set) var loadingOlder = false
    /// Showing the saved copy while the server's answer is on its way.
    private(set) var refreshing = false
    var notice: String?

    private var gen: String?
    private var lastSeq: Int64 = 0
    /// The saved copy shown before the server answered: its generation, and
    /// whether all its seqs belong to that generation.
    private var cachedGen: String?
    private var cachedSeqsMatch = false
    /// False while the oldest entries came from a saved copy of an older
    /// generation: their seq means nothing to the server, so page by uuid.
    private var olderBySeq = true
    @ObservationIgnored private var task: Task<Void, Never>?

    init(conn: ServerConnection, id: String) {
        self.conn = conn
        self.id = id
        self.summary = conn.sessions[id]
    }

    var ref: SessionRef { SessionRef(server: conn.id, session: id) }

    func start() {
        guard task == nil, let api = conn.api else { return }
        task = Task { [weak self] in
            await self?.showSaved()
            var delay: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                // A snapshot of the rows the transcript renders, gzipped. With a
                // saved copy, name a few of its entries: the server answers with
                // only what came after them (a delta) when it still has one.
                var query = ["tail": String(TranscriptWindow.initial), "compress": "gzip"]
                if let gen = self.gen {
                    query["gen"] = gen
                    query["since"] = String(self.lastSeq)
                } else if !self.anchors.isEmpty {
                    query["after"] = self.anchors.joined(separator: ",")
                }
                do {
                    for try await data in api.events("/sessions/\(self.id)/events", query: query) {
                        self.connected = true
                        delay = 1
                        await self.handle(data)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    if let e = error as? APIError, e.status == 404 {
                        self.notice = tr("Session not found")
                        return
                    }
                }
                // Stopped, not dropped: a controller kept to be reopened
                // shouldn't come back showing a lost connection.
                if Task.isCancelled { return }
                self.connected = false
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 10)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        save(flush: true)
    }

    // MARK: - Saved copy

    /// Shows the transcript as last seen, before the network answers.
    private func showSaved() async {
        guard entries.isEmpty, let t = await LocalCache.shared.transcript(server: conn.id, session: id) else { return }
        guard entries.isEmpty, !Task.isCancelled else { return }
        DebugHooks.mark("cache \(t.entries.count) entries")
        entries = t.entries
        hasMore = t.hasMore
        cachedGen = t.gen
        cachedSeqsMatch = t.seqsMatchGen == true
        olderBySeq = false
        refreshing = true
        rebuild()
        loaded = true
    }

    /// Newest user/assistant entries, newest first: entries that stay in the
    /// server's log (live-only result rows vanish when it reloads one).
    private var anchors: [String] {
        Array(entries.reversed().lazy.filter { $0.kind == "user" || $0.kind == "assistant" }.prefix(5).map(\.uuid))
    }

    private func save(flush: Bool = false) {
        guard let gen, !entries.isEmpty else { return }
        LocalCache.shared.store(server: conn.id, session: id,
                                CachedTranscript(gen: gen, lastSeq: lastSeq, hasMore: hasMore, entries: entries, seqsMatchGen: olderBySeq),
                                flush: flush)
    }

    // MARK: - Events

    private func handle(_ data: Data) async {
        let dec = WireDate.decoder
        guard let env = try? dec.decode(EventEnvelope.self, from: data) else { return }
        switch env.type {
        case "snapshot":
            DebugHooks.mark("snapshot received \(data.count) bytes")
            // Snapshots can be large; decode off the main actor.
            let decoded = await Task.detached { try? WireDate.decoder.decode(SnapshotEvent.self, from: data) }.value
            guard let ev = decoded else { return }
            gen = ev.gen
            entries = ev.entries
            lastSeq = ev.entries.last?.seq ?? 0
            hasMore = ev.hasMore
            olderBySeq = true
            partial = ev.partial
            permissions = ev.permissions
            setSummary(ev.session)
            DebugHooks.mark("snapshot \(ev.entries.count) entries")
            rebuild()
            DebugHooks.mark("built \(items.count) items")
            loaded = true
            refreshing = false
            save()
        case "delta":
            // The saved copy up to the anchor is still right; anything after
            // it (live-only rows) is replaced by what the server sent.
            DebugHooks.mark("delta received \(data.count) bytes")
            let decoded = await Task.detached { try? WireDate.decoder.decode(DeltaEvent.self, from: data) }.value
            guard let ev = decoded else { return }
            if let i = entries.lastIndex(where: { $0.uuid == ev.anchor }) {
                entries = Array(entries[...i]) + ev.entries
                // Seqs of the kept entries still hold if the log is the same generation.
                olderBySeq = cachedSeqsMatch && cachedGen == ev.gen
            } else {
                entries = ev.entries
                hasMore = true
                olderBySeq = true
            }
            gen = ev.gen
            lastSeq = ev.entries.last?.seq ?? ev.anchorSeq
            partial = ev.partial
            permissions = ev.permissions
            setSummary(ev.session)
            DebugHooks.mark("delta \(ev.entries.count) entries after anchor")
            rebuild()
            loaded = true
            refreshing = false
            save()
        case "entries":
            guard let ev = try? dec.decode(EntriesEvent.self, from: data) else { return }
            if ev.gen != gen { return }
            let fresh = ev.entries.filter { $0.seq > lastSeq }
            guard !fresh.isEmpty else { return }
            entries.append(contentsOf: fresh)
            lastSeq = fresh.last!.seq
            rebuild()
            save()
        case "partial":
            guard let ev = try? dec.decode(PartialEvent.self, from: data) else { return }
            partial = ev.partial
        case "session":
            guard let ev = try? dec.decode(SessionEvent.self, from: data) else { return }
            setSummary(ev.session)
        case "permission":
            guard let ev = try? dec.decode(PermissionEvent.self, from: data) else { return }
            if !permissions.contains(where: { $0.id == ev.permission.id }) {
                permissions.append(ev.permission)
            }
        case "permissions":
            guard let ev = try? dec.decode(PermissionsEvent.self, from: data) else { return }
            permissions = ev.permissions
        case "permission_resolved":
            guard let ev = try? dec.decode(PermissionResolvedEvent.self, from: data) else { return }
            permissions.removeAll { $0.id == ev.id }
        case "notice":
            guard let ev = try? dec.decode(NoticeEvent.self, from: data) else { return }
            notice = ev.text
        default:
            break
        }
    }

    private func setSummary(_ s: SessionSummary) {
        summary = s
        conn.upsert(s)
    }

    private func rebuild() {
        items = TranscriptBuilder.items(from: entries)
    }

    // MARK: - Actions

    func loadOlder() async {
        guard hasMore, !loadingOlder, let first = entries.first, let api = conn.api else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            // Entries from a saved copy of an older generation are found by uuid.
            let query = olderBySeq ? ["before": String(first.seq), "limit": "300"] : ["beforeUuid": first.uuid, "limit": "300"]
            let page: EntriesPage = try await api.get("/sessions/\(id)/entries", query: query)
            if let g = page.gen, g != gen { return }
            entries.insert(contentsOf: page.entries, at: 0)
            // An unknown uuid gives nothing: the server no longer has those.
            hasMore = page.entries.isEmpty ? false : (page.hasMore ?? false)
            olderBySeq = true
            rebuild()
            save()
        } catch {
            notice = error.localizedDescription
        }
    }

    enum SendResult: Equatable {
        case sent
        /// Held by the server until the other program's turn ends.
        case queued(String)
        case failed
    }

    func send(_ text: String, images: [WireImage] = []) async -> SendResult {
        do {
            struct B: Encodable { var text: String; var images: [WireImage]? }
            // 202 with `queued` when another program is mid-turn; older
            // servers send right away.
            struct R: Decodable { var queued: String? }
            let r: R = try await conn.requireAPI().send("POST", "/sessions/\(id)/messages",
                                                        body: B(text: text, images: images.isEmpty ? nil : images))
            return r.queued.map(SendResult.queued) ?? .sent
        } catch let e as APIError where e.status == 409 || e.message.localizedCaseInsensitiveContains("does not exist") || e.message.contains("ENOENT") {
            // 409: the server says this session can only be viewed here (SSH / missing folder).
            conn.markFolderMissing(id)
            notice = e.message
            return .failed
        } catch {
            notice = error.localizedDescription
            return .failed
        }
    }

    /// Takes a queued message back. False when it was already sent (404).
    func cancelQueued(_ qid: String) async -> Bool {
        do {
            try await conn.requireAPI().delete("/sessions/\(id)/queue/\(qid)")
            return true
        } catch let e as APIError where e.status == 404 {
            notice = tr("That message was already sent.")
            return false
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    /// Forks the session (POST /sessions/{id}/fork) and sends the message to
    /// the fork, leaving the original to the program that holds it. Returns
    /// the fork, already sent to.
    func fork(_ text: String, images: [WireImage] = []) async -> SessionSummary? {
        struct B: Encodable { var text: String?; var images: [WireImage]? }
        do {
            let s: SessionSummary = try await conn.requireAPI().send("POST", "/sessions/\(id)/fork",
                                                                    body: B(text: text.isEmpty ? nil : text, images: images.isEmpty ? nil : images))
            conn.upsert(s)
            return s
        } catch let e as APIError where e.status == 404 || e.status == 405 {
            notice = tr("This server can't fork sessions yet (it needs a newer binaryd).")
            return nil
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    func interrupt() async {
        do {
            let _: OK = try await conn.requireAPI().post("/sessions/\(id)/interrupt")
        } catch {
            notice = error.localizedDescription
        }
    }

    func stopProcess() async {
        do {
            try await conn.stop(id)
        } catch {
            notice = error.localizedDescription
        }
    }

    func update(_ u: SettingsUpdate) async {
        do {
            let r: UpdateResponse = try await conn.requireAPI().send("PATCH", "/sessions/\(id)", body: u)
            setSummary(r.session)
            if let w = r.warnings, !w.isEmpty { notice = w.joined(separator: "\n") }
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Effort

    /// A level picked but not sent yet (slider drag, ⌘[ / ⌘]); "" is Default.
    private(set) var effortDraft: String?
    @ObservationIgnored private var effortSend: Task<Void, Never>?

    /// The level to show: the draft while one is pending.
    var effort: String { effortDraft ?? summary?.effort ?? "" }

    var effortLevels: [String] { conn.effortLevels(for: summary?.model ?? summary?.lastModel) }

    /// What Default came to on the last turn, while the level is Default.
    var appliedEffort: String? { effort.isEmpty ? summary?.appliedEffort : nil }

    /// Shows `level` without sending it (while the slider is dragged).
    func previewEffort(_ level: String) {
        effortSend?.cancel()
        effortSend = nil
        effortDraft = level
    }

    /// Sends `level` after `delay` seconds, so stepping through levels
    /// quickly ends in a single PATCH.
    func setEffort(_ level: String, after delay: Double = 0.3) {
        previewEffort(level)
        // Holds the controller, so a quick switch to another session still
        // sends the level.
        effortSend = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            // Past the pause the request goes out whatever comes next.
            self.effortSend = nil
            if level != (self.summary?.effort ?? "") {
                await self.update(SettingsUpdate(effort: level))
            }
            if self.effortSend == nil, self.effortDraft == level { self.effortDraft = nil }
        }
    }

    /// One level down or up, clamped at the ends. From Default it steps from
    /// what Default came to; when that isn't known (or the model lacks the
    /// level), up goes to high and down to medium. Returns the level now shown.
    @discardableResult
    func stepEffort(_ d: Int) -> String? {
        let levels = effortLevels
        guard !levels.isEmpty else { return nil }
        let next: String
        if let i = levels.firstIndex(of: effort) ?? appliedEffort.flatMap({ levels.firstIndex(of: $0) }) {
            next = levels[max(0, min(levels.count - 1, i + d))]
        } else {
            let mid = levels.count / 2
            next = levels.first { $0 == (d > 0 ? "high" : "medium") } ?? levels[d > 0 ? mid : max(0, mid - 1)]
        }
        if next != effort { setEffort(next) }
        return next
    }

    func respond(_ req: PermissionRequest, _ d: PermissionDecision) async {
        do {
            let _: OK = try await conn.requireAPI().send("POST", "/sessions/\(id)/permissions/\(req.id)", body: d)
            permissions.removeAll { $0.id == req.id }
        } catch {
            notice = error.localizedDescription
        }
    }
}

/// Groups entries into display rows; tool results attach to their call.
enum TranscriptBuilder {
    static func items(from entries: [Entry]) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var toolIndex: [String: Int] = [:]
        for e in entries {
            let blocks = e.blocks ?? []
            switch e.kind {
            case "user":
                var texts: [String] = []
                var images: [String?] = []
                for (i, b) in blocks.enumerated() {
                    switch b.type {
                    case "tool_result":
                        if let tid = b.toolUseId, let idx = toolIndex[tid], case .tool(let use, _) = out[idx].kind {
                            out[idx].kind = .tool(use: use, result: b)
                        } else {
                            out.append(TranscriptItem(id: "\(e.uuid)-\(i)", kind: .tool(use: Block(type: "tool_use", name: tr("Tool result")), result: b), time: e.time))
                        }
                    case "image":
                        images.append(b.image)
                    default:
                        if let t = b.text { texts.append(t) }
                    }
                }
                if !texts.isEmpty || !images.isEmpty {
                    out.append(TranscriptItem(id: e.uuid, kind: .user(text: texts.joined(separator: "\n\n"), images: images), time: e.time))
                }
            case "assistant":
                for (i, b) in blocks.enumerated() {
                    let id = "\(e.uuid)-\(i)"
                    switch b.type {
                    case "text":
                        out.append(TranscriptItem(id: id, kind: .assistant(text: b.text ?? ""), time: e.time))
                    case "thinking":
                        out.append(TranscriptItem(id: id, kind: .thinking(text: b.text ?? ""), time: e.time))
                    case "tool_use":
                        if let tid = b.id { toolIndex[tid] = out.count }
                        out.append(TranscriptItem(id: id, kind: .tool(use: b, result: nil), time: e.time))
                    case "tool_result":
                        if let tid = b.toolUseId, let idx = toolIndex[tid], case .tool(let use, _) = out[idx].kind {
                            out[idx].kind = .tool(use: use, result: b)
                        }
                    default:
                        break
                    }
                }
            case "system":
                out.append(TranscriptItem(id: e.uuid, kind: .system(subtype: e.subtype ?? "", text: e.text ?? "", isError: e.isError ?? false, event: e.event), time: e.time))
            case "result":
                out.append(TranscriptItem(id: e.uuid, kind: .result(e), time: e.time))
            default:
                break
            }
        }
        return out
    }

}

/// What TranscriptView needs from a live session or a read-only subagent.
@MainActor
protocol TranscriptSource: AnyObject, Observable {
    var items: [TranscriptItem] { get }
    var hasMore: Bool { get }
    var loadingOlder: Bool { get }
    var partial: Partial? { get }
    /// Tool calls without a result show a spinner while this is true.
    var transcriptBusy: Bool { get }
    /// Shown at the bottom while busy and nothing is streaming.
    var activityText: String? { get }
    var waitingForApproval: Bool { get }
    var cwd: String? { get }
    func loadOlder() async
}

extension SessionController: TranscriptSource {
    var transcriptBusy: Bool { summary?.status.isBusy == true }
    var activityText: String? {
        guard let s = summary, s.status.isBusy else { return nil }
        return s.activity ?? s.status.label
    }
    var waitingForApproval: Bool { summary?.status == .waiting }
    var cwd: String? { summary?.cwd }
}
