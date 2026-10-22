import Foundation

/// One session row, with the sessions started from it nested below.
struct SidebarNode: Identifiable {
    let session: SessionSummary
    let ref: SessionRef
    var children: [SidebarNode] = []
    var pinned = false
    var archived = false
    var id: SessionRef { ref }

    /// Pending approvals in nested sessions, shown on the parent.
    var childPending: Int { children.reduce(0) { $0 + $1.session.pending + $1.childPending } }
}

struct SidebarGroup: Identifiable {
    let name: String
    var nodes: [SidebarNode]
    var collapsed: Bool
    var id: String { name }
}

/// A session row in an area that spans servers.
struct PlacedNode: Identifiable {
    let node: SidebarNode
    let conn: ServerConnection
    var id: SessionRef { node.ref }
}

struct MergedGroup: Identifiable {
    let name: String
    var items: [PlacedNode]
    var collapsed: Bool
    var id: String { name }
}

/// Pinned sessions and groups from every server, shown above the servers'
/// own (ungrouped) sessions. Nil while searching or showing the archive.
struct MergedSidebar {
    var pinned: [PlacedNode] = []
    var groups: [MergedGroup] = []
    var groupNames: [String] { groups.map(\.name) }
}

/// What the sidebar shows for one server.
struct SidebarSection: Identifiable {
    let conn: ServerConnection
    /// Search results and the archive are shown as one flat list.
    var flat: [SidebarNode]?
    var pinned: [SidebarNode] = []
    var groups: [SidebarGroup] = []
    var ungrouped: [SidebarNode] = []
    var id: UUID { conn.id }

    var isEmpty: Bool { (flat ?? []).isEmpty && pinned.isEmpty && groups.isEmpty && ungrouped.isEmpty }
    var groupNames: [String] { groups.map(\.name) }
}

/// Sessions that show up on more than one server. Claude desktop mirrors an
/// SSH session's transcript to this Mac under the same id, so the same session
/// can be listed by This Mac (view-only) and by the machine that runs it.
struct MirrorIndex {
    /// Per server: ids hidden there, each mapped to the server shown instead.
    var target: [UUID: [String: UUID]] = [:]
    /// Per server: parent links taken from a hidden copy (the copy on This Mac
    /// has the desktop's parentId; the Linux side has none).
    var parents: [UUID: [String: String]] = [:]

    func hidden(on server: UUID) -> Set<String> { target[server].map { Set($0.keys) } ?? [] }

    /// Where a selection should go: the other copy when this one is hidden.
    func redirect(_ ref: SessionRef) -> SessionRef? {
        guard let t = target[ref.server]?[ref.session] else { return nil }
        return SessionRef(server: t, session: ref.session, agent: ref.agent)
    }

    /// A desktop SSH mirror: has sshHost, or (record gone) a Linux home path
    /// listed by a Mac server.
    @MainActor
    static func isMirror(_ s: SessionSummary, on c: ServerConnection) -> Bool {
        s.sshHost != nil || (c.info?.os == "darwin" && s.cwd.hasPrefix("/home/"))
    }

    @MainActor
    init(_ conns: [ServerConnection]) {
        let online = conns.filter { $0.status == .online }
        guard online.count > 1 else { return }
        // Which online servers list each id, and where it can be driven.
        var listedOn: [String: [ServerConnection]] = [:]
        var live: [String: UUID] = [:]
        for c in online {
            for s in c.sessions.values {
                listedOn[s.id, default: []].append(c)
                if live[s.id] == nil && !c.isViewOnly(s) { live[s.id] = c.id }
            }
        }
        for c in conns {
            for s in c.sessions.values where c.isViewOnly(s) {
                guard let others = listedOn[s.id]?.filter({ $0.id != c.id }), !others.isEmpty else { continue }
                var to: ServerConnection?
                if let l = live[s.id], l != c.id {
                    // (a) another server can drive it.
                    to = others.first { $0.id == l }
                } else if Self.isMirror(s, on: c) {
                    // (b) a desktop mirror: show the copy on the machine it lives on,
                    // even when that one is view-only too.
                    to = others.first { o in o.sessions[s.id].map { !Self.isMirror($0, on: o) } ?? false }
                }
                guard let to else { continue }
                target[c.id, default: [:]][s.id] = to.id
                if let p = s.parentId, to.sessions[s.id]?.parentId == nil, to.sessions[p] != nil {
                    parents[to.id, default: [:]][s.id] = p
                }
            }
        }
    }

    init() {}
}

/// Where a row sits in the sidebar (see `SidebarBuilder.place`).
struct RowPlace: Equatable {
    enum Area: Equatable {
        case pinned
        case group(String)
        /// A server's own section; folding it hides the row unless it's a
        /// search or archive list.
        case server(foldable: Bool)
    }
    var area: Area
    /// Rows the session is nested under, outermost first.
    var ancestors: [SessionRef]
}

@MainActor
enum SidebarBuilder {
    static let recentWindow: TimeInterval = 3 * 86400

    static func build(_ conn: ServerConnection, org: SessionOrganizer, query: String,
                      mirrors: MirrorIndex = MirrorIndex()) -> SidebarSection {
        let layout = org.layout(conn.id)
        let hidden = org.showMirrors ? [] : mirrors.hidden(on: conn.id)
        let all = hidden.isEmpty ? conn.sessions : conn.sessions.filter { !hidden.contains($0.key) }
        let extraParents = mirrors.parents[conn.id] ?? [:]
        func parent(_ s: SessionSummary) -> String? { s.parentId ?? extraParents[s.id] }
        let order = sorter(org.sort)
        var section = SidebarSection(conn: conn)

        func node(_ s: SessionSummary) -> SidebarNode {
            SidebarNode(session: s, ref: SessionRef(server: conn.id, session: s.id),
                        pinned: layout.pinned.contains(s.id), archived: layout.archived.contains(s.id))
        }

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            section.flat = all.values.filter { matches($0, q) }.sorted(by: order).map(node)
            return section
        }
        if org.filter == .archived {
            section.flat = all.values.filter { layout.archived.contains($0.id) }.sorted(by: order).map(node)
            return section
        }

        let cutoff = Date().addingTimeInterval(-recentWindow)
        func shown(_ s: SessionSummary) -> Bool {
            // Archived sessions come back while they wait for an approval.
            if layout.archived.contains(s.id) && s.pending == 0 { return false }
            if org.filter == .all { return true }
            return layout.pinned.contains(s.id) || s.live || s.status != .idle || s.pending > 0 || s.updatedAt > cutoff
        }

        // Sessions started from another session nest under it; a shown
        // session with a shown ancestor appears inside that ancestor's tree.
        var childrenOf: [String: [SessionSummary]] = [:]
        for s in all.values {
            if let p = parent(s), p != s.id, all[p] != nil { childrenOf[p, default: []].append(s) }
        }
        let candidates = Set(all.values.filter(shown).map(\.id))
        // A nested session that is pinned, or put in another group than its
        // parent's, stands on its own there instead of under its parent.
        func independent(_ s: SessionSummary) -> Bool {
            guard let p = parent(s), let ps = all[p] else { return false }
            return layout.pinned.contains(s.id) || s.group != ps.group
        }
        func hasShownAncestor(_ s: SessionSummary) -> Bool {
            if independent(s) { return false }
            var seen: Set<String> = [s.id]
            var cur = parent(s)
            while let p = cur, let ps = all[p], seen.insert(p).inserted {
                if candidates.contains(p) { return true }
                cur = parent(ps)
            }
            return false
        }
        func tree(_ s: SessionSummary, depth: Int) -> SidebarNode {
            var n = node(s)
            if depth < 4 {
                n.children = (childrenOf[s.id] ?? []).filter { !independent($0) }.sorted(by: order).map { tree($0, depth: depth + 1) }
            }
            return n
        }
        let roots = all.values.filter { candidates.contains($0.id) && !hasShownAncestor($0) }
            .sorted(by: order)
            .map { tree($0, depth: 0) }

        section.pinned = roots.filter(\.pinned)
        let rest = roots.filter { !$0.pinned }
        let byGroup = Dictionary(grouping: rest.filter { $0.session.group != nil }) { $0.session.group! }
        let used = conn.groupNames
        for name in org.orderedGroups(conn.id, inUse: used) {
            let nodes = byGroup[name] ?? []
            // Groups whose sessions are all filtered out stay hidden; groups
            // created here with no sessions yet show so things can be moved in.
            if nodes.isEmpty && used.contains(name) { continue }
            section.groups.append(SidebarGroup(name: name, nodes: nodes, collapsed: org.isCollapsed(name)))
        }
        section.ungrouped = rest.filter { $0.session.group == nil }
        return section
    }

    static func merge(_ sections: [SidebarSection], org: SessionOrganizer) -> MergedSidebar? {
        guard !sections.contains(where: { $0.flat != nil }) else { return nil }
        let order = sorter(org.sort)
        func sorted(_ items: [PlacedNode]) -> [PlacedNode] { items.sorted { order($0.node.session, $1.node.session) } }
        var out = MergedSidebar()
        out.pinned = sorted(sections.flatMap { s in s.pinned.map { PlacedNode(node: $0, conn: s.conn) } })
        let inUse = sections.reduce(into: Set<String>()) { $0.formUnion($1.conn.groupNames) }
        for name in org.orderedGroups(inUse: inUse) {
            let items = sorted(sections.flatMap { s in
                (s.groups.first { $0.name == name }?.nodes ?? []).map { PlacedNode(node: $0, conn: s.conn) }
            })
            // As before: hidden when everything in it is filtered out, shown
            // when it was just created and has nothing yet.
            if items.isEmpty && inUse.contains(name) { continue }
            out.groups.append(MergedGroup(name: name, items: items, collapsed: org.isCollapsed(name)))
        }
        return out
    }

    static func matches(_ s: SessionSummary, _ q: String) -> Bool {
        s.title.lowercased().contains(q) || s.cwd.lowercased().contains(q)
            || (s.preview?.lowercased().contains(q) ?? false) || s.id.hasPrefix(q)
            || (s.group?.lowercased().contains(q) ?? false)
    }

    static func sorter(_ sort: SessionSort) -> (SessionSummary, SessionSummary) -> Bool {
        switch sort {
        case .updated:
            return { $0.updatedAt > $1.updatedAt }
        case .created:
            return { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.updatedAt > $1.updatedAt }
        case .title:
            return { a, b in
                let r = a.title.localizedStandardCompare(b.title)
                return r == .orderedSame ? a.updatedAt > b.updatedAt : r == .orderedAscending
            }
        case .project:
            return { a, b in
                let r = a.cwd.localizedStandardCompare(b.cwd)
                return r == .orderedSame ? a.updatedAt > b.updatedAt : r == .orderedAscending
            }
        }
    }

    /// Where a session's row is drawn: the area holding it and the rows it is
    /// nested under (outermost first). A session pinned, or in another group
    /// than its parent, stands on its own, so a parent link alone says
    /// nothing about where it is. Nil when the row isn't in the list.
    static func place(of session: SessionRef, sections: [SidebarSection], merged: MergedSidebar?) -> RowPlace? {
        func path(in nodes: [SidebarNode], _ above: [SessionRef] = []) -> [SessionRef]? {
            for n in nodes {
                if n.ref == session { return above }
                if let p = path(in: n.children, above + [n.ref]) { return p }
            }
            return nil
        }
        if let merged {
            if let p = path(in: merged.pinned.map(\.node)) { return RowPlace(area: .pinned, ancestors: p) }
            for g in merged.groups {
                if let p = path(in: g.items.map(\.node)) { return RowPlace(area: .group(g.name), ancestors: p) }
            }
        }
        for s in sections where s.conn.id == session.server {
            if let flat = s.flat {
                return path(in: flat).map { RowPlace(area: .server(foldable: false), ancestors: $0) }
            }
            if let p = path(in: s.pinned) { return RowPlace(area: .pinned, ancestors: p) }
            for g in s.groups {
                if let p = path(in: g.nodes) { return RowPlace(area: .group(g.name), ancestors: p) }
            }
            if let p = path(in: s.ungrouped) { return RowPlace(area: .server(foldable: true), ancestors: p) }
        }
        return nil
    }

    /// How many recent subagents show before "Show all".
    static let agentPreview = 5

    /// Subagents listed under a session (newest first): the most recent few,
    /// unless the list is opened fully.
    static func shownAgents(_ all: [SubagentInfo], showAll: Bool) -> [SubagentInfo] {
        guard !showAll, all.count > agentPreview + 1 else { return all }
        return Array(all.prefix(agentPreview))
    }

    /// Rows in display order, for keyboard navigation and ⇧-click ranges.
    static func visibleOrder(_ sections: [SidebarSection], merged: MergedSidebar? = nil, org: SessionOrganizer,
                             showAll: Set<SessionRef> = []) -> [SessionRef] {
        var out: [SessionRef] = []
        func walk(_ n: SidebarNode, _ conn: ServerConnection) {
            out.append(n.ref)
            guard org.isExpanded(n.ref) else { return }
            for c in n.children { walk(c, conn) }
            for a in shownAgents(conn.subagents[n.session.id] ?? [], showAll: showAll.contains(n.ref)) {
                out.append(SessionRef(server: n.ref.server, session: n.session.id, agent: a.id))
            }
        }
        if let merged {
            if !org.pinnedCollapsed { merged.pinned.forEach { walk($0.node, $0.conn) } }
            for g in merged.groups where !g.collapsed { g.items.forEach { walk($0.node, $0.conn) } }
        }
        for s in sections {
            // Folded servers are skipped by ⌥⌘↑/↓; search results still count.
            if s.flat == nil, org.isServerCollapsed(s.conn.id) { continue }
            if let flat = s.flat {
                flat.forEach { walk($0, s.conn) }
                continue
            }
            if merged == nil {
                s.pinned.forEach { walk($0, s.conn) }
                for g in s.groups where !g.collapsed { g.nodes.forEach { walk($0, s.conn) } }
            }
            s.ungrouped.forEach { walk($0, s.conn) }
        }
        return out
    }
}
