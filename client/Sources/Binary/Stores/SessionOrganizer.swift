import Foundation
import Observation

enum SessionSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case updated, created, title, project
    var id: String { rawValue }

    var label: String {
        switch self {
        case .updated: return tr("Recent Activity")
        case .created: return tr("Created")
        case .title: return tr("Title")
        case .project: return tr("Project Folder")
        }
    }
}

enum SessionFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case recent, all, archived
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return tr("Recent")
        case .all: return tr("All")
        case .archived: return tr("Archived")
        }
    }
}

/// Client-side organization of one server's sessions. Group membership itself
/// lives on the server (the session's tag); this holds what the server
/// doesn't know about.
struct ServerLayout: Codable, Equatable, Sendable {
    var pinned: Set<String> = []
    var archived: Set<String> = []
    /// Group display order. Also keeps groups that have no sessions yet.
    var groups: [String] = []
    var collapsed: Set<String> = []
    /// Sessions whose nested rows (child sessions and subagents) are shown.
    var expanded: Set<String> = []
    /// The whole server section is folded down to its header.
    var sectionCollapsed = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
        archived = try c.decodeIfPresent(Set<String>.self, forKey: .archived) ?? []
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        collapsed = try c.decodeIfPresent(Set<String>.self, forKey: .collapsed) ?? []
        expanded = try c.decodeIfPresent(Set<String>.self, forKey: .expanded) ?? []
        sectionCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sectionCollapsed) ?? false
    }
}

/// Pinned, archived, group order, collapsed state, sort and filter. Persisted
/// to sidebar.json next to servers.json.
@MainActor
@Observable
final class SessionOrganizer {
    private(set) var layouts: [UUID: ServerLayout] = [:]
    var sort: SessionSort = .updated { didSet { save() } }
    var filter: SessionFilter = .recent { didSet { save() } }
    /// Show This Mac's view-only copies of sessions another server runs.
    var showMirrors = false { didSet { save() } }
    /// Groups span servers: one display order and folded state for a name,
    /// whichever servers have sessions tagged with it.
    private(set) var groupOrder: [String] = []
    private(set) var collapsedGroups: Set<String> = []
    var pinnedCollapsed = false { didSet { save() } }

    @ObservationIgnored private var loading = false
    private let fileURL = ClientFiles.url("sidebar.json")

    private struct Stored: Codable {
        var sort: SessionSort?
        var filter: SessionFilter?
        var showMirrors: Bool?
        var groupOrder: [String]?
        var collapsedGroups: Set<String>?
        var pinnedCollapsed: Bool?
        var servers: [String: ServerLayout]?
    }

    init() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        sort = s.sort ?? .updated
        filter = s.filter ?? .recent
        showMirrors = s.showMirrors ?? false
        for (k, v) in s.servers ?? [:] {
            if let id = UUID(uuidString: k) { layouts[id] = v }
        }
        pinnedCollapsed = s.pinnedCollapsed ?? false
        if let order = s.groupOrder {
            groupOrder = order
            collapsedGroups = s.collapsedGroups ?? []
        } else {
            // Before groups spanned servers: each server kept its own order.
            for l in layouts.values {
                for g in l.groups where !groupOrder.contains(g) { groupOrder.append(g) }
                collapsedGroups.formUnion(l.collapsed)
            }
        }
    }

    func layout(_ server: UUID) -> ServerLayout { layouts[server] ?? ServerLayout() }

    private func edit(_ server: UUID, _ f: (inout ServerLayout) -> Void) {
        var l = layouts[server] ?? ServerLayout()
        f(&l)
        if l != layouts[server] {
            layouts[server] = l
            save()
        }
    }

    // MARK: Pin / archive

    func isPinned(_ ref: SessionRef) -> Bool { layout(ref.server).pinned.contains(ref.session) }
    func isArchived(_ ref: SessionRef) -> Bool { layout(ref.server).archived.contains(ref.session) }

    func setPinned(_ refs: [SessionRef], _ on: Bool) {
        for (server, ids) in Dictionary(grouping: refs, by: \.server) {
            edit(server) { l in
                for r in ids {
                    if on {
                        l.pinned.insert(r.session)
                        l.archived.remove(r.session)
                    } else {
                        l.pinned.remove(r.session)
                    }
                }
            }
        }
    }

    func setArchived(_ refs: [SessionRef], _ on: Bool) {
        for (server, ids) in Dictionary(grouping: refs, by: \.server) {
            edit(server) { l in
                for r in ids {
                    if on {
                        l.archived.insert(r.session)
                        l.pinned.remove(r.session)
                    } else {
                        l.archived.remove(r.session)
                    }
                }
            }
        }
    }

    // MARK: Groups
    // Shared by all servers; a group's members are sessions tagged with its
    // name on whichever server they live.

    func isCollapsed(_ group: String) -> Bool { collapsedGroups.contains(group) }
    func isCollapsed(_ server: UUID, _ group: String) -> Bool { isCollapsed(group) }

    func toggleCollapsed(_ group: String) {
        if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        save()
    }
    func toggleCollapsed(_ server: UUID, _ group: String) { toggleCollapsed(group) }

    /// Group names in display order: the saved order first, then any other
    /// group in use, alphabetically.
    func orderedGroups(inUse: Set<String>) -> [String] {
        let rest = inUse.subtracting(groupOrder).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return groupOrder + rest
    }
    func orderedGroups(_ server: UUID, inUse: Set<String>) -> [String] { orderedGroups(inUse: inUse) }

    func addGroup(_ name: String) {
        if !groupOrder.contains(name) { groupOrder.append(name) }
        collapsedGroups.remove(name)
        save()
    }
    func addGroup(_ server: UUID, _ name: String) { addGroup(name) }

    /// Records the full display order, e.g. after a reorder.
    func setGroupOrder(_ order: [String]) {
        groupOrder = order
        save()
    }
    func setGroupOrder(_ server: UUID, _ order: [String]) { setGroupOrder(order) }

    func renameGroup(_ old: String, _ new: String) {
        if let i = groupOrder.firstIndex(of: old) {
            groupOrder[i] = new
            groupOrder = groupOrder.enumerated().filter { $0.element != new || $0.offset == i }.map(\.element)
        } else if !groupOrder.contains(new) {
            groupOrder.append(new)
        }
        if collapsedGroups.remove(old) != nil { collapsedGroups.insert(new) }
        save()
    }
    func renameGroup(_ server: UUID, _ old: String, _ new: String) { renameGroup(old, new) }

    func removeGroup(_ name: String) {
        groupOrder.removeAll { $0 == name }
        collapsedGroups.remove(name)
        save()
    }
    func removeGroup(_ server: UUID, _ name: String) { removeGroup(name) }

    // MARK: Server sections

    func isServerCollapsed(_ server: UUID) -> Bool { layout(server).sectionCollapsed }

    func setServerCollapsed(_ server: UUID, _ on: Bool) {
        edit(server) { $0.sectionCollapsed = on }
    }

    /// ⌥-click: this server open, every other one folded.
    func collapseOthers(_ server: UUID, among all: [UUID]) {
        for s in all { setServerCollapsed(s, s != server) }
    }

    func expandAll(_ all: [UUID]) {
        for s in all { setServerCollapsed(s, false) }
    }

    // MARK: Subagent rows

    func isExpanded(_ ref: SessionRef) -> Bool { layout(ref.server).expanded.contains(ref.session) }

    func setExpanded(_ ref: SessionRef, _ on: Bool) {
        edit(ref.server) { l in
            if on { l.expanded.insert(ref.session) } else { l.expanded.remove(ref.session) }
        }
    }

    // MARK: Persistence

    private func save() {
        guard !loading else { return }
        let stored = Stored(sort: sort, filter: filter, showMirrors: showMirrors,
                            groupOrder: groupOrder, collapsedGroups: collapsedGroups, pinnedCollapsed: pinnedCollapsed,
                            servers: Dictionary(uniqueKeysWithValues: layouts.map { ($0.key.uuidString, $0.value) }))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(stored) else { return }
        ClientFiles.write(data, to: fileURL)
    }
}
