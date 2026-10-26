import Foundation
import Observation

struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var token: String
}

/// Identifies one session on one server, or one subagent inside it.
struct SessionRef: Hashable, Sendable {
    var server: UUID
    var session: String
    var agent: String? = nil

    /// The session itself, without the subagent part.
    var sessionOnly: SessionRef { SessionRef(server: server, session: session) }
}

/// The configured servers and their live connections. Persisted to
/// ~/Library/Application Support/Binary/servers.json (mode 0600, like the
/// server's own server.json).
@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [ServerConfig] = []
    private(set) var connections: [UUID: ServerConnection] = [:]

    /// Forwarded to every connection; used for notifications.
    @ObservationIgnored var onTransition: ((ServerConnection, SessionSummary?, SessionSummary) -> Void)? {
        didSet { for c in connections.values { c.onTransition = onTransition } }
    }

    /// Called with every server's layout as it arrives; the organizer and the
    /// projects follow the servers through it.
    @ObservationIgnored private var layoutObservers: [(ServerConnection, SharedLayout) -> Void] = []

    private let fileURL = ClientFiles.url("servers.json")

    init() {
        load()
        if servers.isEmpty, let local = Self.localServerConfig() {
            servers = [local]
            save()
        }
        for s in servers { connect(s) }
    }

    var orderedConnections: [ServerConnection] {
        servers.compactMap { connections[$0.id] }
    }

    func connection(_ id: UUID) -> ServerConnection? { connections[id] }

    /// Calls `f` with each server's layout from now on, starting with those
    /// already received.
    func observeLayouts(_ f: @escaping (ServerConnection, SharedLayout) -> Void) {
        layoutObservers.append(f)
        for c in orderedConnections {
            if let l = c.layout { f(c, l) }
        }
    }

    func add(_ config: ServerConfig) {
        servers.append(config)
        save()
        connect(config)
    }

    func update(_ config: ServerConfig) {
        guard let i = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[i] = config
        save()
        connections[config.id]?.stop()
        connect(config)
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        connections[id]?.stop()
        connections[id] = nil
        save()
    }

    func move(from: IndexSet, to: Int) {
        servers.move(fromOffsets: from, toOffset: to)
        save()
    }

    private func connect(_ config: ServerConfig) {
        let conn = ServerConnection(config: config)
        conn.onTransition = onTransition
        conn.onLayout = { [weak self] c, l in self?.layoutObservers.forEach { $0(c, l) } }
        connections[config.id] = conn
        conn.start()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return }
        servers = list
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(servers) else { return }
        ClientFiles.write(data, to: fileURL, private: true)
    }

    /// Reads a binaryd config on this Mac (~/.binary/server.json) so a local
    /// server works with no setup. A phone runs no binaryd.
    static func localServerConfig() -> ServerConfig? {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = ProcessInfo.processInfo.environment["BINARY_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".binary")
        struct Local: Decodable { var listen: String?; var token: String; var tlsCert: String? }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("server.json")),
              let cfg = try? JSONDecoder().decode(Local.self, from: data) else { return nil }
        var listen = cfg.listen ?? "127.0.0.1:7350"
        if listen.hasPrefix("0.0.0.0:") || listen.hasPrefix(":") {
            listen = "127.0.0.1:" + (listen.split(separator: ":").last.map(String.init) ?? "7350")
        }
        let scheme = (cfg.tlsCert ?? "").isEmpty ? "http" : "https"
        return ServerConfig(name: tr("This Mac"), url: "\(scheme)://\(listen)", token: cfg.token)
        #else
        return nil
        #endif
    }
}
