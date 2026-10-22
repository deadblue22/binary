import Foundation
import Observation

struct EnvVar: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var key: String
    var value: String

    /// Letters, digits and underscores, not starting with a digit.
    static func isValidName(_ k: String) -> Bool {
        guard let first = k.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return k.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }
}

/// A place to start sessions: a folder on a server, plus how to start there
/// (branch, worktree, environment variables). Kept on this Mac only.
struct Project: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var server: UUID
    var folder: String
    /// Branch to start from; nil means whatever is checked out.
    var branch: String?
    var worktree = false
    var env: [EnvVar] = []
    /// New-session settings: what the last session started here used, or
    /// what was set in the project editor. Empty means the server default.
    var model = ""
    var effort = ""
    var permissionMode = ""
    var starred = false
    var lastUsed: Date?

    init(name: String, server: UUID, folder: String) {
        self.name = name
        self.server = server
        self.folder = folder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        server = try c.decode(UUID.self, forKey: .server)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        worktree = try c.decodeIfPresent(Bool.self, forKey: .worktree) ?? false
        env = try c.decodeIfPresent([EnvVar].self, forKey: .env) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? ""
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? ""
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
    }

    var startConfig: StartConfig {
        get { StartConfig(branch: branch, worktree: worktree, model: model, effort: effort, permissionMode: permissionMode) }
        set {
            branch = newValue.branch
            worktree = newValue.worktree
            model = newValue.model
            effort = newValue.effort
            permissionMode = newValue.permissionMode
        }
    }

    var envDictionary: [String: String] {
        Dictionary(env.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }, uniquingKeysWith: { _, b in b })
    }

    static func defaultName(for folder: String) -> String {
        let last = (folder as NSString).lastPathComponent
        return last.isEmpty ? folder : last
    }
}

/// Where a new session starts: a saved project, or just a folder.
struct StartTarget: Codable, Hashable {
    var server: UUID
    var folder: String
    var project: UUID?
}

/// How a new session starts in a project or folder.
struct StartConfig: Codable, Hashable, Sendable {
    var branch: String?
    var worktree = false
    var model = ""
    var effort = ""
    var permissionMode = ""
}

/// projects.json next to servers.json; new-session.json keeps the last
/// place a session was started and the settings used in plain folders.
private struct StartMemory: Codable {
    var last: StartTarget?
    var folders: [String: StartConfig] = [:]
}

/// projects.json next to servers.json.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private var memory = StartMemory()
    private let fileURL = ClientFiles.url("projects.json")
    private let memoryURL = ClientFiles.url("new-session.json")

    init() {
        if let data = try? Data(contentsOf: memoryURL), let m = try? JSONDecoder().decode(StartMemory.self, from: data) {
            memory = m
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        projects = (try? dec.decode([Project].self, from: data)) ?? []
    }

    /// Where the last new session was started.
    var lastTarget: StartTarget? { memory.last }

    /// The settings a new session in this project or folder starts with.
    func config(for t: StartTarget) -> StartConfig {
        if let p = project(t.project) ?? project(server: t.server, folder: t.folder) { return p.startConfig }
        return memory.folders[Self.key(t)] ?? StartConfig()
    }

    /// A session was started here with these settings: they become the
    /// defaults for the next one, and this the default place.
    func remember(_ t: StartTarget, _ c: StartConfig) {
        if let i = projects.firstIndex(where: { $0.id == t.project || ($0.server == t.server && $0.folder == t.folder) }) {
            projects[i].startConfig = c
            projects[i].lastUsed = Date()
            persist()
        } else {
            memory.folders[Self.key(t)] = c
        }
        memory.last = t
        persistMemory()
    }

    private static func key(_ t: StartTarget) -> String { "\(t.server.uuidString)|\(t.folder)" }

    private func persistMemory() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        ClientFiles.write(data, to: memoryURL)
    }

    /// Starred projects in the order they were starred; ⌥⌘1…9 pick the first nine.
    var favorites: [Project] { projects.filter(\.starred) }

    func projects(on server: UUID) -> [Project] {
        projects.filter { $0.server == server }
            .sorted { ($0.lastUsed ?? .distantPast, $1.name) > ($1.lastUsed ?? .distantPast, $0.name) }
    }

    func project(_ id: UUID?) -> Project? { id.flatMap { i in projects.first { $0.id == i } } }

    func project(server: UUID, folder: String) -> Project? {
        projects.first { $0.server == server && $0.folder == folder }
    }

    func save(_ p: Project) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) {
            projects[i] = p
        } else {
            projects.append(p)
        }
        persist()
    }

    func delete(_ id: UUID) {
        projects.removeAll { $0.id == id }
        persist()
    }

    func setStarred(_ id: UUID, _ on: Bool) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        var p = projects.remove(at: i)
        p.starred = on
        // Newly starred ones go last so existing shortcuts keep their number.
        projects.append(p)
        persist()
    }

    func markUsed(_ id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].lastUsed = Date()
        persist()
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(projects) else { return }
        ClientFiles.write(data, to: fileURL)
    }
}
