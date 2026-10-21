import Foundation

/// A session's transcript as last seen: shown at once when the session is
/// opened again, then brought up to date by the server.
struct CachedTranscript: Codable, Sendable {
    var gen: String
    var lastSeq: Int64
    var hasMore: Bool
    var entries: [Entry]
    /// Every entry's seq belongs to `gen`. False when older entries were kept
    /// from a copy of an earlier generation: those are paged by uuid.
    var seqsMatchGen: Bool?
}

/// What the client keeps between opens and launches, so a slow link isn't
/// waited on: recently opened transcripts (in memory, and on disk), each
/// server's last session list, and the images messages refer to.
///
/// On disk it lives in `<client dir>/cache/<server id>/`. The files hold
/// conversation text, so the directories are 0700 and the files 0600; the
/// whole cache is capped, least recently used files going first.
@MainActor
final class LocalCache {
    static let shared = LocalCache()

    /// Transcripts kept in memory per server.
    static let memorySessions = 30
    /// Entries kept per transcript in memory and on disk.
    static let memoryEntries = 600
    static let diskEntries = 200
    static let diskLimit: Int64 = 200 * 1024 * 1024

    let root = ClientFiles.url("cache")

    private var memory: [UUID: [String: CachedTranscript]] = [:]
    /// Per server, least recently used first.
    private var order: [UUID: [String]] = [:]
    /// Writes waiting out their pause, by key.
    private var writes: [String: (task: Task<Void, Never>, url: URL, encode: @Sendable () throws -> Data)] = [:]
    private var lastTrim = Date.distantPast

    private init() {
        // Old files from a previous run count against the cap too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.trimSoon() }
    }

    // MARK: Transcripts

    func transcript(server: UUID, session: String) async -> CachedTranscript? {
        if let t = memory[server]?[session] {
            remember(server, session, t)
            return t
        }
        let url = transcriptURL(server, session)
        let t = await Task.detached { () -> CachedTranscript? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return try? WireDate.decoder.decode(CachedTranscript.self, from: data)
        }.value
        if let t { remember(server, session, t) }
        return t
    }

    /// Keeps the transcript in memory now and writes it to disk after a
    /// pause (right away with `flush`).
    func store(server: UUID, session: String, _ t: CachedTranscript, flush: Bool = false) {
        var t = t
        if t.entries.count > Self.memoryEntries {
            t.entries = Array(t.entries.suffix(Self.memoryEntries))
            t.hasMore = true
        }
        remember(server, session, t)
        var disk = t
        if disk.entries.count > Self.diskEntries {
            disk.entries = Array(disk.entries.suffix(Self.diskEntries))
            disk.hasMore = true
        }
        let saved = disk
        write(transcriptURL(server, session), key: "\(server)/\(session)", delay: flush ? 0 : 2) {
            try WireDate.encoder().encode(saved)
        }
    }

    private func remember(_ server: UUID, _ session: String, _ t: CachedTranscript) {
        memory[server, default: [:]][session] = t
        var o = order[server, default: []]
        o.removeAll { $0 == session }
        o.append(session)
        while o.count > Self.memorySessions {
            memory[server]?[o.removeFirst()] = nil
        }
        order[server] = o
    }

    // MARK: Session lists

    /// The server's session list as last seen, for the sidebar at launch.
    func sessions(server: UUID) -> [SessionSummary]? {
        guard let data = try? Data(contentsOf: serverDir(server).appendingPathComponent("sessions.json")) else { return nil }
        return try? WireDate.decoder.decode([SessionSummary].self, from: data)
    }

    func storeSessions(server: UUID, _ list: [SessionSummary]) {
        write(serverDir(server).appendingPathComponent("sessions.json"), key: "\(server)/sessions", delay: 5) {
            try WireDate.encoder().encode(list)
        }
    }

    // MARK: Images

    /// Image keys don't change, so a cached copy never goes stale.
    func image(server: UUID, session: String, key: String) -> Data? {
        let url = imageURL(server, session, key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func storeImage(server: UUID, session: String, key: String, _ data: Data) {
        let url = imageURL(server, session, key)
        let dir = url.deletingLastPathComponent()
        Task.detached {
            Self.makeDirectory(dir)
            Self.writePrivate(data, to: url)
        }
        trimSoon()
    }

    // MARK: Size and clearing

    /// Bytes on disk.
    nonisolated func size() async -> Int64 {
        let root = self.root
        return await Task.detached { Self.files(in: root).reduce(0) { $0 + $1.size } }.value
    }

    /// Drops everything, in memory and on disk.
    func clear() {
        writes.values.forEach { $0.task.cancel() }
        writes = [:]
        memory = [:]
        order = [:]
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes what is waiting out its pause now (the app is quitting).
    func flushAll() {
        let pending = writes.values
        writes = [:]
        for w in pending {
            w.task.cancel()
            guard let data = try? w.encode() else { continue }
            Self.makeDirectory(w.url.deletingLastPathComponent())
            Self.writePrivate(data, to: w.url)
        }
    }

    // MARK: Files

    private func serverDir(_ server: UUID) -> URL { root.appendingPathComponent(server.uuidString, isDirectory: true) }

    private func transcriptURL(_ server: UUID, _ session: String) -> URL {
        serverDir(server).appendingPathComponent("transcripts", isDirectory: true).appendingPathComponent(Self.fileName(session) + ".json")
    }

    private func imageURL(_ server: UUID, _ session: String, _ key: String) -> URL {
        serverDir(server).appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(Self.fileName(session) + "-" + Self.fileName(key))
    }

    /// Ids and keys as file names: anything but letters, digits, "-" and "_" becomes "_".
    nonisolated static func fileName(_ s: String) -> String {
        String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
    }

    private func write(_ url: URL, key: String, delay: Double, encode: @escaping @Sendable () throws -> Data) {
        writes[key]?.task.cancel()
        let task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.writes[key] = nil
            await Task.detached {
                guard let data = try? encode() else { return }
                Self.makeDirectory(url.deletingLastPathComponent())
                Self.writePrivate(data, to: url)
            }.value
            self?.trimSoon()
        }
        writes[key] = (task, url, encode)
    }

    nonisolated private static func makeDirectory(_ dir: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    nonisolated private static func writePrivate(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// At most once a minute: drop the least recently used files until the
    /// cache is back under 90% of its limit.
    private func trimSoon() {
        guard Date().timeIntervalSince(lastTrim) > 60 else { return }
        lastTrim = Date()
        let root = self.root, limit = Self.diskLimit
        Task.detached(priority: .background) {
            var files = Self.files(in: root)
            var total = files.reduce(0) { $0 + $1.size }
            guard total > limit else { return }
            files.sort { $0.used < $1.used }
            for f in files where total > limit * 9 / 10 {
                try? FileManager.default.removeItem(at: f.url)
                total -= f.size
            }
        }
    }

    nonisolated private static func files(in root: URL) -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [(URL, Int64, Date)] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append((url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
        }
        return out
    }
}
