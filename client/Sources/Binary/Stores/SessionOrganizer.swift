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

/// How sessions outside the groups are listed: as one list per server, or
/// split by project folder. Groups show either way.
enum SessionGrouping: String, Codable, Sendable {
    case groups, project
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
/// lives on the server (the session's tag); pinned and archived are kept on
/// newer servers too (`SharedLayout`) and synced, the rest is this client's.
struct ServerLayout: Codable, Equatable, Sendable {
    var pinned: Set<String> = []
    var archived: Set<String> = []
    /// When pinned / archived last changed, as the server stamps them (ms);
    /// 0 when never synced with it.
    var pinnedAt: Double = 0
    var archivedAt: Double = 0
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
        pinnedAt = try c.decodeIfPresent(Double.self, forKey: .pinnedAt) ?? 0
        archivedAt = try c.decodeIfPresent(Double.self, forKey: .archivedAt) ?? 0
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        collapsed = try c.decodeIfPresent(Set<String>.self, forKey: .collapsed) ?? []
        expanded = try c.decodeIfPresent(Set<String>.self, forKey: .expanded) ?? []
        sectionCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sectionCollapsed) ?? false
    }
}

/// Pinned, archived, group order, collapsed state, sort, filter and grouping. Persisted
/// to sidebar.json next to servers.json; pinned, archived and the group order
/// are also kept on newer servers, so every client shows the same (newest
/// change wins, field by field).

@MainActor
@Observable
final class SessionOrganizer {
    private(set) var layouts: [UUID: ServerLayout] = [:]
    var sort: SessionSort = .updated { didSet { save() } }
    var filter: SessionFilter = .recent { didSet { save() } }
    var grouping: SessionGrouping = .groups { didSet { save() } }
    /// Show This Mac's view-only copies of sessions another server runs.
    var showMirrors = false { didSet { save() } }
    /// Groups span servers: one display order and folded state for a name,
    /// whichever servers have sessions tagged with it.
    private(set) var groupOrder: [String] = []
    /// When the group order last changed (ms), as on the servers; 0 when never synced.
    @ObservationIgnored private var groupOrderAt: Double = 0
    private(set) var collapsedGroups: Set<String> = []
    var pinnedCollapsed = false { didSet { save() } }
    /// Folded project sections, as `ProjectKey.id` (server and folder).
    private(set) var collapsedProjects: Set<String> = []

    @ObservationIgnored private var loading = false
    @ObservationIgnored private weak var store: ServerStore?
    private let fileURL = ClientFiles.url("sidebar.json")

    private struct Stored: Codable {
        var sort: SessionSort?
        var filter: SessionFilter?
        var grouping: SessionGrouping?
        var showMirrors: Bool?
        var groupOrder: [String]?
        var groupOrderAt: Double?
        var collapsedGroups: Set<String>?
        var pinnedCollapsed: Bool?
        var collapsedProjects: Set<String>?
        var servers: [String: ServerLayout]?
    }

    init() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        sort = s.sort ?? .updated
        filter = s.filter ?? .recent
        grouping = s.grouping ?? .groups
        collapsedProjects = s.collapsedProjects ?? []
        showMirrors = s.showMirrors ?? false
        for (k, v) in s.servers ?? [:] {
            if let id = UUID(uuidString: k) { layouts[id] = v }
        }
        pinnedCollapsed = s.pinnedCollapsed ?? false
        if let order = s.groupOrder {
            groupOrder = order
            groupOrderAt = s.groupOrderAt ?? 0
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
        let old = layouts[server] ?? ServerLayout()
        var l = old
        f(&l)
        guard l != old else { return }
        // Pinned and archived go to the server too, stamped now.
        var u = LayoutUpdate()
        let known = store?.connection(server)?.layout?.at
        if l.pinned != old.pinned {
            l.pinnedAt = Self.stamp(after: max(old.pinnedAt, known?.pinned ?? 0))
            u.pinned = l.pinned.sorted()
            u.at["pinned"] = l.pinnedAt
        }
        if l.archived != old.archived {
            l.archivedAt = Self.stamp(after: max(old.archivedAt, known?.archived ?? 0))
            u.archived = l.archived.sorted()
            u.at["archived"] = l.archivedAt
        }
        layouts[server] = l
        save()
        if !u.isEmpty { send(u, to: server) }
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
        if !groupOrder.contains(name) {
            groupOrder.append(name)
            groupOrderChanged()
        }
        collapsedGroups.remove(name)
        save()
    }
    func addGroup(_ server: UUID, _ name: String) { addGroup(name) }

    /// Records the full display order, e.g. after a reorder.
    func setGroupOrder(_ order: [String]) {
        guard order != groupOrder else { return }
        groupOrder = order
        groupOrderChanged()
        save()
    }
    func setGroupOrder(_ server: UUID, _ order: [String]) { setGroupOrder(order) }

    func renameGroup(_ old: String, _ new: String) {
        let before = groupOrder
        if let i = groupOrder.firstIndex(of: old) {
            groupOrder[i] = new
            groupOrder = groupOrder.enumerated().filter { $0.element != new || $0.offset == i }.map(\.element)
        } else if !groupOrder.contains(new) {
            groupOrder.append(new)
        }
        if groupOrder != before { groupOrderChanged() }
        if collapsedGroups.remove(old) != nil { collapsedGroups.insert(new) }
        save()
    }
    func renameGroup(_ server: UUID, _ old: String, _ new: String) { renameGroup(old, new) }

    func removeGroup(_ name: String) {
        if groupOrder.contains(name) {
            groupOrder.removeAll { $0 == name }
            groupOrderChanged()
        }
        collapsedGroups.remove(name)
        save()
    }
    func removeGroup(_ server: UUID, _ name: String) { removeGroup(name) }

    // MARK: Projects

    func isProjectCollapsed(_ id: String) -> Bool { collapsedProjects.contains(id) }

    func setProjectCollapsed(_ id: String, _ on: Bool) {
        guard on != collapsedProjects.contains(id) else { return }
        if on { collapsedProjects.insert(id) } else { collapsedProjects.remove(id) }
        save()
    }

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

    // MARK: Sync with servers

    private static var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    /// The stamp for a change made now: later than `known` even when this
    /// device's clock is behind the one that set it, so the server takes it.
    private static func stamp(after known: Double) -> Double { max(now, known + 1) }

    /// Follows the servers' layouts from now on, and catches up with those
    /// already received.
    func sync(with store: ServerStore) {
        self.store = store
        store.onLayout = { [weak self] conn, l in self?.merge(conn.id, l) }
        for c in store.orderedConnections {
            if let l = c.layout { merge(c.id, l) }
        }
    }

    /// Takes a server's layout: per field, whichever side changed it last
    /// wins, and what is newer here goes back to the server. What this client
    /// kept before it ever synced (pins from before servers stored them) is
    /// added to the server's, not dropped.
    private func merge(_ server: UUID, _ remote: SharedLayout) {
        var l = layout(server)
        var u = LayoutUpdate()
        func sync(_ local: inout Set<String>, _ at: inout Double, _ theirs: [String], _ theirAt: Double, _ key: String) -> [String]? {
            let remoteSet = Set(theirs)
            if at == 0 {
                let union = remoteSet.union(local)
                local = union
                if union == remoteSet { at = theirAt; return nil }
                at = Self.stamp(after: theirAt)
            } else if theirAt > at {
                local = remoteSet
                at = theirAt
                return nil
            } else if at == theirAt {
                return nil
            }
            u.at[key] = at
            return local.sorted()
        }
        u.pinned = sync(&l.pinned, &l.pinnedAt, remote.pinned, remote.at.pinned, "pinned")
        u.archived = sync(&l.archived, &l.archivedAt, remote.archived, remote.at.archived, "archived")
        if l != layouts[server] {
            layouts[server] = l
            save()
        }

        // The group order spans servers: the newest copy wins on all of them.
        if groupOrderAt == 0 {
            let union = remote.groupOrder + groupOrder.filter { !remote.groupOrder.contains($0) }
            groupOrder = union
            groupOrderAt = union == remote.groupOrder ? remote.at.groupOrder : Self.stamp(after: remote.at.groupOrder)
            save()
        } else if remote.at.groupOrder > groupOrderAt {
            groupOrder = remote.groupOrder
            groupOrderAt = remote.at.groupOrder
            save()
        }
        if !u.isEmpty { send(u, to: server) }
        spreadGroupOrder()
    }

    /// The group order changed here: stamp it and send it everywhere.
    private func groupOrderChanged() {
        guard !loading else { return }
        let known = (store?.orderedConnections ?? []).compactMap { $0.layout?.at.groupOrder }.max() ?? 0
        groupOrderAt = Self.stamp(after: max(groupOrderAt, known))
        spreadGroupOrder()
    }

    /// Sends the group order to the servers holding an older one.
    private func spreadGroupOrder() {
        for c in store?.orderedConnections ?? [] {
            guard let l = c.layout, l.at.groupOrder < groupOrderAt else { continue }
            send(LayoutUpdate(groupOrder: groupOrder, at: ["groupOrder": groupOrderAt]), to: c.id)
        }
    }

    /// Sends to servers that keep layouts; older ones don't.
    private func send(_ u: LayoutUpdate, to server: UUID) {
        guard let c = store?.connection(server), c.layout != nil else { return }
        Task { await c.sendLayout(u) }
    }

    // MARK: Persistence

    private func save() {
        guard !loading else { return }
        let stored = Stored(sort: sort, filter: filter, grouping: grouping, showMirrors: showMirrors,
                            groupOrder: groupOrder, groupOrderAt: groupOrderAt, collapsedGroups: collapsedGroups, pinnedCollapsed: pinnedCollapsed,
                            collapsedProjects: collapsedProjects,
                            servers: Dictionary(uniqueKeysWithValues: layouts.map { ($0.key.uuidString, $0.value) }))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(stored) else { return }
        ClientFiles.write(data, to: fileURL)
    }
}
