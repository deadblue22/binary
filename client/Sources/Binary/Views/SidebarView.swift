import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(SessionOrganizer.self) private var org
    @Environment(ProjectStore.self) private var projects
    @Environment(\.theme) private var theme
    /// Drop zones (group rows) currently under a drag, as "group|row" keys.
    @State private var dropHover: Set<String> = []
    @State private var query = ""
    @State private var content = ContentSearch()
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    /// Rows picked with ⌘/⇧-click for batch actions.
    @State private var batch: Set<SessionRef> = []
    @State private var anchor: SessionRef?
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var notice: String?
    /// Sessions whose whole subagent list is open.
    @State private var showAllAgents: Set<SessionRef> = []

    var body: some View {
        let mirrors = MirrorIndex(store.orderedConnections)
        let sections = store.orderedConnections.map {
            SidebarBuilder.build($0, org: org, query: query, starred: projects.starredFolders(on: $0.id), mirrors: mirrors, hits: content.hits(for: $0.id, query: query))
        }
        let merged = SidebarBuilder.merge(sections, org: org)
        let order = SidebarBuilder.visibleOrder(sections, merged: merged, org: org, showAll: showAllAgents)
        VStack(spacing: 0) {
            topBar(sections)
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a LazyVStack of these rows could keep placing
                    // them again every frame after the list changed under the
                    // pointer, hanging the app at full CPU. The list is a few
                    // hundred rows at most, cheap to lay out in full.
                    VStack(alignment: .leading, spacing: 2) {
                        if let merged { mergedView(merged) }
                        ForEach(sections) { section in
                            sectionView(section, mirrors: mirrors, merged: merged != nil)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                    .slimScrollers()
                }
                .scrollIndicators(.automatic)
                .onAppear {
                    // No anchor: scroll only when the row is out of view.
                    nav.scrollHandler = { ref in proxy.scrollTo(ref) }
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { nav.step(-1); return .handled }
            .onKeyPress(.downArrow) { nav.step(1); return .handled }
            UsageFooter()
            if let notice {
                NoticeBar(text: notice) { self.notice = nil }
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if self.notice == notice { self.notice = nil }
                    }
            }
        }
        .background(theme.c.sidebar)
        .onAppear { nav.visibleOrder = order }
        .onChange(of: order) { _, o in nav.visibleOrder = o }
        .onChange(of: nav.searchRequest) { _, _ in searchFocused = true }
        .task(id: query) { await content.run(query, on: store.orderedConnections) }
        .task {
            guard let q = DebugHooks.env["BINARY_SEARCH"] else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            query = q
        }
        .onChange(of: content.query) { _, _ in
            guard DebugHooks.env["BINARY_OPEN_MATCH"] == "1",
                  let n = sections.lazy.compactMap({ $0.flat?.first { $0.hit != nil } }).first,
                  let sn = n.hit?.snippets.first else { return }
            nav.open(n.ref, at: sn.uuid)
        }
        // Kept out of this body so a selection change re-renders only the rows involved.
        .background(SelectionWatcher { s in
            if let s, redirectIfMirror(s) { return }
            if let s, !batch.contains(s) { batch = [] }
            if let s { reveal(s) }
        })
        // A copy can become hidden after it was picked (its server came online later).
        .onChange(of: mirrors.target.values.reduce(0) { $0 + $1.count }) { _, _ in
            if let s = nav.selection { _ = redirectIfMirror(s) }
        }
        .toolbar {
            ToolbarItem {
                Button { nav.newSession() } label: {
                    Label(tr("New Session"), systemImage: "square.and.pencil")
                }
                .help(tr("New Session (⌘N)"))
            }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { p in
            TextField(p.placeholder, text: $promptText)
            Button(tr("Cancel"), role: .cancel) {}
            Button(p.confirm) { commit(p, promptText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } message: { p in
            if let m = p.message { Text(m) }
        }
    }

    // MARK: Top bar

    private func topBar(_ sections: [SidebarSection]) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.c.textFaint)
                PlainField(placeholder: tr("Search titles, folders, content, groups"), text: $query, focus: $searchFocused)
                    .foregroundStyle(theme.c.text)
                    .onExitCommand { query = ""; searchFocused = false }
                if content.running {
                    ProgressView().controlSize(.mini)
                }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.c.textFaint)
                }
            }
            .font(theme.font(.callout))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous).fill(theme.c.input))
            .overlay(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                .strokeBorder(searchFocused ? theme.c.focus : theme.c.border, lineWidth: searchFocused ? 1.5 : 1))

            Menu {
                Picker(tr("Show"), selection: Binding(get: { org.filter }, set: { org.filter = $0 })) {
                    ForEach(SessionFilter.allCases) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.inline)
                Toggle(tr("Show Copies from Other Servers"), isOn: Binding(get: { org.showMirrors }, set: { org.showMirrors = $0 }))
                Toggle(tr("Ungrouped Sessions by Project"), isOn: Binding(get: { org.grouping == .project }, set: { org.grouping = $0 ? .project : .groups }))
                Picker(tr("Sort"), selection: Binding(get: { org.sort }, set: { org.sort = $0 })) {
                    ForEach(SessionSort.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.inline)
                Divider()
                if let first = store.orderedConnections.first {
                    Button(tr("New Group…")) { ask(.newGroup(first.id, [])) }
                }
            } label: {
                let plain = org.filter == .recent && org.sort == .updated && org.grouping == .groups
                Image(systemName: plain ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: theme.size(.body) + 2))
                    .foregroundStyle(plain ? theme.c.textMuted : theme.c.focus)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(org.grouping == .project
                  ? tr("Showing \(org.filter.label) · by project · sorted by \(org.sort.label)")
                  : tr("Showing \(org.filter.label) · sorted by \(org.sort.label)"))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: Sections

    // MARK: Pinned and groups (all servers)

    /// Without an icon, a header's name already sits left of its sessions' titles.
    private var memberIndent: CGFloat { 0 }

    /// Server names on rows only when there is more than one server.
    private func serverTag(_ conn: ServerConnection) -> String? {
        store.orderedConnections.count > 1 ? conn.displayName : nil
    }

    @ViewBuilder
    private func mergedView(_ merged: MergedSidebar) -> some View {
        if !merged.pinned.isEmpty {
            GroupHeader(name: tr("Pinned"), count: merged.pinned.count, collapsed: org.pinnedCollapsed,
                        payload: "", highlighted: zoneActive("pinned")) {
                org.pinnedCollapsed.toggle()
            } onDrop: { items in
                dropAny(items) { refs in org.setPinned(refs, true) }
            } menu: {
                Button(org.pinnedCollapsed ? tr("Expand") : tr("Collapse")) { org.pinnedCollapsed.toggle() }
            }
            .padding(.top, 4)
            if !org.pinnedCollapsed {
                ForEach(merged.pinned) { p in
                    // The header says they're pinned; the row's pin would only take room.
                    var n = p.node
                    let _ = (n.pinned = false)
                    tree(n, conn: p.conn, serverTag: serverTag(p.conn))
                        .padding(.leading, memberIndent)
                        .modifier(dropZone("pinned", p.id) { items in dropAny(items) { refs in org.setPinned(refs, true) } })
                }
            }
        }
        ForEach(merged.groups) { g in
            GroupHeader(name: g.name, count: g.items.count, collapsed: g.collapsed,
                        payload: DragPayload.group(store.orderedConnections.first?.id ?? UUID(), g.name).string,
                        onNew: { newSession(in: g) },
                        insertEdge: { dragged in
                            let names = merged.groupNames
                            guard dragged != g.name, let from = names.firstIndex(of: dragged), let to = names.firstIndex(of: g.name) else { return nil }
                            return from < to ? .bottom : .top
                        },
                        highlighted: zoneActive("g:" + g.name)) {
                org.toggleCollapsed(g.name)
            } onDrop: { items in
                handleMergedGroupDrop(items, target: g.name, merged: merged)
            } menu: {
                mergedGroupMenu(g.name, merged)
            }
            if !g.collapsed {
                let drop: ([String]) -> Bool = { items in handleMergedGroupDrop(items, target: g.name, merged: merged) }
                if g.items.isEmpty {
                    emptyLine(tr("Drag sessions here, or use Move to Group in the context menu"))
                        .padding(.leading, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(dropZone("g:" + g.name, "empty", drop))
                }
                ForEach(g.items) { p in
                    tree(p.node, conn: p.conn, serverTag: serverTag(p.conn))
                        .padding(.leading, memberIndent)
                        .modifier(dropZone("g:" + g.name, p.id, drop))
                }
            }
        }
    }

    private func zoneActive(_ zone: String) -> Bool {
        dropHover.contains { $0.hasPrefix(zone + "|") }
    }

    /// A row of a group that takes session drops for the whole group; only
    /// sessions, so dragging a group over rows doesn't reorder groups.
    private func dropZone<ID: Hashable>(_ zone: String, _ row: ID, _ onDrop: @escaping ([String]) -> Bool) -> GroupDropZone {
        GroupDropZone(key: "\(zone)|\(row)", hovered: $dropHover, active: zoneActive(zone), onDrop: { items in
            let sessions = items.filter { if case .sessions = DragPayload($0) { return true } else { return false } }
            return sessions.isEmpty ? false : onDrop(sessions)
        })
    }

    /// + on a group: a new session in it, starting from the folder of its latest session.
    private func newSession(in g: MergedGroup) {
        nav.newSession(group: g.name, template: g.items.max { $0.node.session.updatedAt < $1.node.session.updatedAt }?.node.ref)
    }

    @ViewBuilder
    private func mergedGroupMenu(_ name: String, _ merged: MergedSidebar) -> some View {
        let order = merged.groupNames
        let i = order.firstIndex(of: name) ?? 0
        let any = store.orderedConnections.first?.id ?? UUID()
        Button(tr("New Session in Group")) {
            if let g = merged.groups.first(where: { $0.name == name }) { newSession(in: g) }
        }
        Divider()
        Button(tr("Rename Group…")) { ask(.renameGroup(any, name)) }
        Button(tr("Move Up")) { reorderGroups(order, name, to: i - 1) }.disabled(i == 0)
        Button(tr("Move Down")) { reorderGroups(order, name, to: i + 1) }.disabled(i >= order.count - 1)
        Divider()
        Button(tr("New Group…")) { ask(.newGroup(any, [])) }
        Button(org.isCollapsed(name) ? tr("Expand") : tr("Collapse")) { org.toggleCollapsed(name) }
        Divider()
        Button(tr("Ungroup")) { dissolveEverywhere(name) }
    }

    private func reorderGroups(_ order: [String], _ name: String, to index: Int) {
        var o = order
        guard let i = o.firstIndex(of: name), index >= 0, index < o.count else { return }
        o.remove(at: i)
        o.insert(name, at: index)
        org.setGroupOrder(o + org.groupOrder.filter { !o.contains($0) })
    }

    private func handleMergedGroupDrop(_ items: [String], target: String, merged: MergedSidebar) -> Bool {
        for item in items {
            switch DragPayload(item) {
            case .sessions(let server, let ids):
                let refs = ids.map { SessionRef(server: server, session: $0) }
                move(refs, to: target)
                // Dragged out of Pinned into a group: it moves there, so it's no longer pinned.
                let pinned = refs.filter { org.isPinned($0) }
                if !pinned.isEmpty { org.setPinned(pinned, false) }
            case .group(_, let name) where name != target:
                // Dropped on a group below it: goes after that group; above: before it.
                let names = merged.groupNames
                let downward = (names.firstIndex(of: name) ?? 0) < (names.firstIndex(of: target) ?? 0)
                var order = names.filter { $0 != name }
                let at = order.firstIndex(of: target).map { downward ? $0 + 1 : $0 } ?? order.count
                order.insert(name, at: at)
                org.setGroupOrder(order + org.groupOrder.filter { !order.contains($0) })
            default:
                return false
            }
        }
        return true
    }

    /// Sessions dropped from any server.
    private func dropAny(_ items: [String], _ apply: ([SessionRef]) -> Void) -> Bool {
        var refs: [SessionRef] = []
        for item in items {
            if case .sessions(let server, let ids) = DragPayload(item) {
                refs += ids.map { SessionRef(server: server, session: $0) }
            }
        }
        guard !refs.isEmpty else { return false }
        apply(refs)
        return true
    }

    private func dissolveEverywhere(_ name: String) {
        for conn in store.orderedConnections where conn.groupNames.contains(name) {
            dissolve(conn, name)
        }
        org.removeGroup(name)
    }

    // MARK: Servers

    @ViewBuilder
    private func sectionView(_ section: SidebarSection, mirrors: MirrorIndex, merged: Bool = false) -> some View {
        let conn = section.conn
        let all = store.orderedConnections.map(\.id)
        // Search shows matches even in folded servers, without unfolding them.
        let folded = org.isServerCollapsed(conn.id) && section.flat == nil
        let hiddenMirrors = org.showMirrors ? [] : mirrors.hidden(on: conn.id)
        ServerHeader(conn: conn, collapsed: org.isServerCollapsed(conn.id), searching: section.flat != nil && !query.isEmpty,
                     hidden: hiddenMirrors,
                     multipleServers: all.count > 1,
                     onToggle: {
                         if NSEvent.modifierFlags.contains(.option) {
                             // As in Finder: ⌥-click folds every other server.
                             org.collapseOthers(conn.id, among: all)
                         } else {
                             org.setServerCollapsed(conn.id, !org.isServerCollapsed(conn.id))
                         }
                     },
                     onCollapseOthers: { org.collapseOthers(conn.id, among: all) },
                     onExpandAll: { org.expandAll(all) },
                     onNewGroup: { ask(.newGroup(conn.id, [])) })
            .padding(.top, 8)
        if folded {
            EmptyView()
        } else if let flat = section.flat {
            if flat.isEmpty {
                emptyLine(query.isEmpty ? tr("No archived sessions") : tr("No matches"))
            }
            ForEach(flat) { n in tree(n, conn: conn) }
        } else {
            if !merged && !section.pinned.isEmpty {
                SectionLabel(title: tr("Pinned"), icon: "pin.fill", count: section.pinned.count) {
                    drop($0, conn) { refs in org.setPinned(refs, true) }
                }
                ForEach(section.pinned) { n in tree(n, conn: conn) }
            }
            ForEach(merged ? [] : section.groups) { g in
                GroupHeader(name: g.name, count: g.nodes.count, collapsed: g.collapsed,
                            payload: DragPayload.group(conn.id, g.name).string,
                            highlighted: zoneActive("s:\(conn.id):" + g.name)) {
                    org.toggleCollapsed(conn.id, g.name)
                } onDrop: { items in
                    handleGroupDrop(items, conn: conn, target: g.name, section: section)
                } menu: {
                    groupMenu(conn, g.name, section)
                }
                if !g.collapsed {
                    let zone = "s:\(conn.id):" + g.name
                    let drop: ([String]) -> Bool = { items in handleGroupDrop(items, conn: conn, target: g.name, section: section) }
                    if g.nodes.isEmpty {
                        emptyLine(tr("Drag sessions here, or use Move to Group in the context menu"))
                            .padding(.leading, 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(dropZone(zone, "empty", drop))
                    }
                    ForEach(g.nodes) { n in
                        tree(n, conn: conn).modifier(dropZone(zone, n.id, drop))
                    }
                }
            }
            if !merged && !section.groups.isEmpty && !section.ungrouped.isEmpty {
                SectionLabel(title: tr("Ungrouped"), icon: "tray", count: section.ungrouped.count) {
                    drop($0, conn) { refs in move(refs, to: "") }
                }
            }
            ForEach(section.projects) { p in projectView(p, conn: conn) }
            if !section.otherProjects.isEmpty { otherProjectsView(section, conn: conn) }
            ForEach(section.ungrouped) { n in tree(n, conn: conn) }
            if (merged ? section.ungrouped.isEmpty && section.projects.isEmpty && section.otherProjects.isEmpty : section.isEmpty), conn.status == .online {
                emptyLine(org.filter == .recent ? tr("No activity in the last 3 days") : tr("No sessions"))
            }
        }
        if !folded && !hiddenMirrors.isEmpty {
            let hosts = Set(hiddenMirrors.compactMap { mirrors.target[conn.id]?[$0] }).compactMap { store.connection($0)?.displayName }.sorted()
            HiddenMirrorsLine(count: hiddenMirrors.count, hosts: hosts) { org.showMirrors = true }
        }
    }

    @ViewBuilder
    private func projectView(_ p: ProjectGroup, conn: ServerConnection) -> some View {
        let toggle = { org.setProjectCollapsed(p.id, !p.collapsed) }
        ProjectHeader(name: p.name, folder: p.folder, count: p.nodes.count, collapsed: p.collapsed, busy: p.busy,
                      onNew: { newSession(in: p) }, onToggle: toggle) {
            Button(tr("New Session in Project")) { newSession(in: p) }
            Divider()
            if !p.folder.isEmpty {
                Button(tr("Copy Path")) { copy(p.folder) }
                if conn.isLocal {
                    Button(tr("Show in Finder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.folder) }
                }
                Divider()
            }
            Button(p.collapsed ? tr("Expand") : tr("Collapse"), action: toggle)
            Divider()
            Button(tr("Archive Project's Sessions")) { archive(p, conn) }
        }
        if !p.collapsed {
            ForEach(p.nodes) { n in tree(n, conn: conn) }
        }
    }

    /// Projects that aren't starred, folded into one section until wanted.
    @ViewBuilder
    private func otherProjectsView(_ section: SidebarSection, conn: ServerConnection) -> some View {
        let collapsed = section.otherProjectsCollapsed
        let toggle = { org.setOtherProjectsCollapsed(conn.id, !collapsed) }
        ProjectHeader(name: tr("Other Projects"), folder: "", count: section.otherProjects.reduce(0) { $0 + $1.nodes.count },
                      collapsed: collapsed, busy: section.otherProjects.reduce(0) { $0 + $1.busy }, onToggle: toggle) {
            Button(collapsed ? tr("Expand") : tr("Collapse"), action: toggle)
        }
        if !collapsed {
            VStack(spacing: 0) {
                ForEach(section.otherProjects) { p in projectView(p, conn: conn) }
            }
            .padding(.leading, 14)
        }
    }

    /// Archives every session in the project, so it leaves the list; they
    /// stay under Archived.
    private func archive(_ p: ProjectGroup, _ conn: ServerConnection) {
        let refs = p.allSessions(on: conn)
        org.setArchived(refs, true)
        batch = []
        notice = tr("Archived \(refs.count) sessions of \(p.name). Show → Archived lists them.")
    }

    /// + on a project: a new session in its folder.
    private func newSession(in p: ProjectGroup) {
        let latest = p.nodes.max { $0.session.updatedAt < $1.session.updatedAt }?.ref
        nav.newSession(template: latest, folder: p.folder.isEmpty ? nil : p.folder)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(theme.c.textFaint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    /// A session row plus, when expanded, its child sessions and subagents.
    private func tree(_ n: SidebarNode, conn: ServerConnection, position: TreePosition = TreePosition(depth: 0, isLast: true), serverTag: String? = nil) -> AnyView {
        let expanded = org.isExpanded(n.ref)
        let allAgents = conn.subagents[n.session.id] ?? []
        let showingAll = showAllAgents.contains(n.ref)
        let agents = SidebarBuilder.shownAgents(allAgents, showAll: showingAll)
        let canToggle = allAgents.count > SidebarBuilder.agentPreview + 1
        let expandable = !n.children.isEmpty || (n.session.subagentCount ?? 0) > 0 || !allAgents.isEmpty
        let depth = position.depth
        // Ancestor lines continue past this row's subtree when this row has siblings below.
        let childContinues = depth == 0 ? [] : position.continues + [!position.isLast]
        let rowCount = n.children.count + agents.count + (canToggle ? 1 : 0)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            SessionRow(node: n, position: position, expandable: expandable, expanded: expanded,
                       batched: batch.contains(n.ref) && batch.count > 1,
                       viewOnly: conn.isViewOnly(n.session), serverTag: serverTag) {
                org.setExpanded(n.ref, !expanded)
            }
            .id(n.ref)
            .onTapGesture { click(n.ref) }
            // Alongside the single click, so selecting isn't held back waiting for a second one.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) { ask(.renameSession(n.ref, n.session.title)) }
            })
            .contextMenu { sessionMenu(n, conn) }
            .draggable(DragPayload.sessions(conn.id, targets(n.ref).map(\.session)).string) {
                DragPreview(title: n.session.title, count: targets(n.ref).count)
            }
            if let hit = n.hit {
                ForEach(hit.snippets.prefix(2), id: \.uuid) { sn in
                    SnippetRow(snippet: sn, query: query) {
                        batch = []
                        nav.open(n.ref, at: sn.uuid)
                    }
                }
            }
            if expanded && expandable {
                ForEach(Array(n.children.enumerated()), id: \.element.id) { i, c in
                    tree(c, conn: conn, position: TreePosition(depth: depth + 1, isLast: i == rowCount - 1, continues: childContinues))
                }
                ForEach(Array(agents.enumerated()), id: \.element.id) { i, a in
                    let ref = SessionRef(server: conn.id, session: n.session.id, agent: a.id)
                    SubagentRow(info: a, ref: ref, position: TreePosition(depth: depth + 1, isLast: n.children.count + i == rowCount - 1, continues: childContinues))
                        .id(ref)
                        .onTapGesture { click(ref) }
                        .contextMenu {
                            Button(tr("Copy Subagent ID")) { copy(a.id) }
                        }
                }
                if canToggle {
                    MoreRow(text: agents.count < allAgents.count
                                ? tr("Show all \(allAgents.count) subagents")
                                : tr("Show only the latest \(SidebarBuilder.agentPreview)"),
                            position: TreePosition(depth: depth + 1, isLast: true, continues: childContinues)) {
                        if agents.count < allAgents.count { showAllAgents.insert(n.ref) } else { showAllAgents.remove(n.ref) }
                    }
                }
                if allAgents.isEmpty && n.children.isEmpty {
                    Text(conn.supportsSubagents ? tr("Loading subagents…") : tr("This server can't list subagents"))
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.c.textFaint)
                        .padding(.leading, TreeMetrics.contentX(depth + 1))
                        .padding(.vertical, 3)
                }
            }
        }
        .task(id: expanded && (n.session.subagentCount ?? 0) > 0 ? "\(n.session.id)|\(n.session.updatedAt.timeIntervalSince1970)" : "") {
            guard expanded, (n.session.subagentCount ?? 0) > 0 else { return }
            await conn.loadSubagents(n.session.id)
            // A subagent picked before its list arrived: scroll now that its row exists.
            if let sel = nav.selection, let a = sel.agent, sel.session == n.session.id {
                revealAgent(a, of: n.ref, in: conn)
                try? await Task.sleep(nanoseconds: 100_000_000)
                nav.scroll(to: sel)
            }
        })
    }

    // MARK: Selection

    /// Opens the live copy instead of a hidden mirror (notifications, links,
    /// Back to parent). Returns true when it changed the selection.
    private func redirectIfMirror(_ ref: SessionRef) -> Bool {
        guard !org.showMirrors, let live = MirrorIndex(store.orderedConnections).redirect(ref) else { return false }
        DebugHooks.log("redirect \(ref.session.prefix(8)) -> server \(live.server.uuidString.prefix(4))")
        nav.selection = live
        return true
    }

    /// Opens whatever hides a selected row (collapsed parents, a collapsed
    /// group) and scrolls it into view. Selections also come from
    /// notifications, Task cards and "Back to Parent Session".
    private func reveal(_ ref: SessionRef) {
        guard let conn = store.connection(ref.server) else { return }
        var opened = false
        func expand(_ r: SessionRef) {
            if !org.isExpanded(r) {
                org.setExpanded(r, true)
                opened = true
            }
        }
        if let a = ref.agent {
            expand(ref.sessionOnly)
            revealAgent(a, of: ref.sessionOnly, in: conn)
        }
        // Open only what holds the row as the sidebar draws it: a session
        // pinned or grouped apart from its parent isn't under that parent.
        let mirrors = MirrorIndex(store.orderedConnections)
        let sections = store.orderedConnections.map {
            SidebarBuilder.build($0, org: org, query: query, starred: projects.starredFolders(on: $0.id), mirrors: mirrors, hits: content.hits(for: $0.id, query: query))
        }
        let place = SidebarBuilder.place(of: ref.sessionOnly, sections: sections, merged: SidebarBuilder.merge(sections, org: org))
        switch place?.area {
        case .pinned?:
            if org.pinnedCollapsed {
                org.pinnedCollapsed = false
                opened = true
            }
        case .group(let g)?:
            if org.isCollapsed(ref.server, g) {
                org.toggleCollapsed(ref.server, g)
                opened = true
            }
        case .project(let id, let other)?:
            if org.isServerCollapsed(ref.server) {
                org.setServerCollapsed(ref.server, false)
                opened = true
            }
            if other && org.isOtherProjectsCollapsed(ref.server) {
                org.setOtherProjectsCollapsed(ref.server, false)
                opened = true
            }
            if org.isProjectCollapsed(id) {
                org.setProjectCollapsed(id, false)
                opened = true
            }
        case .server(foldable: true)?:
            if org.isServerCollapsed(ref.server) {
                org.setServerCollapsed(ref.server, false)
                opened = true
            }
        default:
            break
        }
        place?.ancestors.forEach(expand)
        // A nested row lives inside its top-level ancestor's block, which the
        // lazy list only builds near the viewport: bring the ancestor in first.
        let top = place?.ancestors.first
        DebugHooks.log("reveal \(ref.session.prefix(8)) opened=\(opened) top=\(top?.session.prefix(8) ?? "-")")
        DispatchQueue.main.asyncAfter(deadline: .now() + (opened ? 0.25 : 0.05)) {
            guard nav.selection == ref else { return }
            if let top, top != ref.sessionOnly {
                nav.scroll(to: top)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if nav.selection == ref { nav.scroll(to: ref) }
                }
            } else {
                nav.scroll(to: ref)
            }
        }
    }

    /// An older subagent isn't among the few listed by default: list them all.
    private func revealAgent(_ agent: String, of session: SessionRef, in conn: ServerConnection) {
        let all = conn.subagents[session.session] ?? []
        if !SidebarBuilder.shownAgents(all, showAll: showAllAgents.contains(session)).contains(where: { $0.id == agent }),
           all.contains(where: { $0.id == agent }) {
            showAllAgents.insert(session)
        }
    }

    private func click(_ ref: SessionRef) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command), ref.agent == nil {
            if batch.isEmpty, let s = nav.selection, s.agent == nil { batch = [s] }
            if batch.contains(ref) { batch.remove(ref) } else { batch.insert(ref) }
            anchor = ref
            return
        }
        if mods.contains(.shift), ref.agent == nil, let a = anchor ?? nav.selection {
            let order = nav.visibleOrder.filter { $0.agent == nil }
            if let i = order.firstIndex(of: a), let j = order.firstIndex(of: ref) {
                batch = Set(order[min(i, j)...max(i, j)])
                return
            }
        }
        batch = []
        anchor = ref
        nav.selection = ref
    }

    /// The rows an action on `ref` applies to: the batch when `ref` is in it.
    private func targets(_ ref: SessionRef) -> [SessionRef] {
        if batch.count > 1 && batch.contains(ref) {
            return nav.visibleOrder.filter { batch.contains($0) }
        }
        return [ref]
    }


    // MARK: Menus

    @ViewBuilder
    private func sessionMenu(_ n: SidebarNode, _ conn: ServerConnection) -> some View {
        let refs = targets(n.ref)
        let multi = refs.count > 1
        let summaries = refs.compactMap { conn.sessions[$0.session] }
        if multi {
            Text(tr("\(refs.count) sessions selected"))
        }
        let allPinned = refs.allSatisfy { org.isPinned($0) }
        Button(allPinned ? tr("Unpin") : tr("Pin")) { org.setPinned(refs, !allPinned) }
        Menu(tr("Move to Group")) {
            let groups = org.orderedGroups(inUse: store.orderedConnections.reduce(into: Set<String>()) { $0.formUnion($1.groupNames) })
            ForEach(groups, id: \.self) { g in
                let here = summaries.allSatisfy { $0.group == g }
                Button { move(refs, to: g) } label: {
                    if here { Label(g, systemImage: "checkmark") } else { Text(g) }
                }
                .disabled(here)
            }
            if !groups.isEmpty { Divider() }
            Button(tr("New Group…")) { ask(.newGroup(conn.id, refs)) }
            if summaries.contains(where: { $0.group != nil }) {
                Button(tr("Remove from Group")) { move(refs, to: "") }
            }
        }
        let allArchived = refs.allSatisfy { org.isArchived($0) }
        Button(allArchived ? tr("Unarchive") : tr("Archive")) {
            org.setArchived(refs, !allArchived)
            if !allArchived, let s = nav.selection, refs.contains(s.sessionOnly), org.filter != .archived {
                batch = []
            }
        }
        if multi {
            Divider()
            Button(tr("Clear Selection")) { batch = [] }
        } else {
            let s = n.session
            Divider()
            Button(tr("Rename…")) { ask(.renameSession(n.ref, s.title)) }
            Button(tr("New Child Session")) { nav.newChildSession(of: n.ref) }
            Button(tr("Copy Session ID")) { copy(s.id) }
            Button(tr("Copy Resume Command")) { copy(s.resumeCommand) }
            Button(tr("Copy Working Directory")) { copy(s.cwd) }
            if conn.isLocal {
                Button(tr("Show in Finder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
            }
            if s.live {
                Divider()
                Button(tr("Stop Process")) {
                    Task { try? await conn.stop(s.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func groupMenu(_ conn: ServerConnection, _ name: String, _ section: SidebarSection) -> some View {
        let order = section.groupNames
        let i = order.firstIndex(of: name) ?? 0
        Button(tr("Rename Group…")) { ask(.renameGroup(conn.id, name)) }
        Button(tr("Move Up")) { reorder(conn.id, order, name, to: i - 1) }.disabled(i == 0)
        Button(tr("Move Down")) { reorder(conn.id, order, name, to: i + 1) }.disabled(i >= order.count - 1)
        Divider()
        Button(tr("New Group…")) { ask(.newGroup(conn.id, [])) }
        Button(org.isCollapsed(conn.id, name) ? tr("Expand") : tr("Collapse")) { org.toggleCollapsed(conn.id, name) }
        Divider()
        Button(tr("Ungroup")) { dissolve(conn, name) }
    }

    // MARK: Actions

    private func ask(_ p: NamePrompt) {
        promptText = p.initial
        prompt = p
    }

    private func commit(_ p: NamePrompt, _ text: String) {
        guard !text.isEmpty else { return }
        switch p {
        case .renameSession(let ref, _):
            guard let conn = store.connection(ref.server) else { return }
            Task {
                do { try await conn.update(ref.session, SettingsUpdate(title: text)) } catch { notice = error.localizedDescription }
            }
        case .newGroup(let server, let refs):
            org.addGroup(server, text)
            if !refs.isEmpty { move(refs, to: text) }
        case .renameGroup(_, let old):
            // Groups span servers: rename the tag wherever it is used.
            guard text != old else { return }
            Task {
                do {
                    for conn in store.orderedConnections {
                        let ids = conn.sessions.values.filter { $0.group == old }.map(\.id)
                        if !ids.isEmpty { try await conn.setGroup(ids, text) }
                    }
                    org.renameGroup(old, text)
                } catch { notice = error.localizedDescription }
            }
        }
    }

    private func move(_ refs: [SessionRef], to group: String) {
        for (server, list) in Dictionary(grouping: refs.filter { $0.agent == nil }, by: \.server) {
            guard let conn = store.connection(server) else { continue }
            if !group.isEmpty { org.addGroup(server, group) }
            Task {
                do { try await conn.setGroup(list.map(\.session), group) } catch { notice = error.localizedDescription }
            }
        }
    }

    private func dissolve(_ conn: ServerConnection, _ name: String) {
        let ids = conn.sessions.values.filter { $0.group == name }.map(\.id)
        Task {
            do {
                if !ids.isEmpty { try await conn.setGroup(ids, "") }
                org.removeGroup(conn.id, name)
            } catch { notice = error.localizedDescription }
        }
    }

    private func reorder(_ server: UUID, _ order: [String], _ name: String, to index: Int) {
        var o = order
        guard let i = o.firstIndex(of: name), index >= 0, index < o.count else { return }
        o.remove(at: i)
        o.insert(name, at: index)
        // Keep groups that are currently hidden by the filter after the visible ones.
        let hidden = org.layout(server).groups.filter { !o.contains($0) }
        org.setGroupOrder(server, o + hidden)
    }

    private func handleGroupDrop(_ items: [String], conn: ServerConnection, target: String, section: SidebarSection) -> Bool {
        for item in items {
            switch DragPayload(item) {
            case .sessions(let server, let ids) where server == conn.id:
                move(ids.map { SessionRef(server: server, session: $0) }, to: target)
            case .group(let server, let name) where server == conn.id && name != target:
                var order = section.groupNames.filter { $0 != name }
                order.insert(name, at: order.firstIndex(of: target) ?? order.count)
                let hidden = org.layout(conn.id).groups.filter { !order.contains($0) }
                org.setGroupOrder(conn.id, order + hidden)
            default:
                return false
            }
        }
        return true
    }

    private func drop(_ items: [String], _ conn: ServerConnection, _ apply: ([SessionRef]) -> Void) -> Bool {
        var refs: [SessionRef] = []
        for item in items {
            if case .sessions(let server, let ids) = DragPayload(item), server == conn.id {
                refs += ids.map { SessionRef(server: server, session: $0) }
            }
        }
        guard !refs.isEmpty else { return false }
        apply(refs)
        return true
    }
}

/// Reacts to selection changes without making the sidebar body depend on them.
private struct SelectionWatcher: View {
    @Environment(Navigation.self) private var nav
    let onChange: (SessionRef?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: nav.selection) { _, s in onChange(s) }
            .onAppear { onChange(nav.selection) }
    }
}

enum NamePrompt {
    case renameSession(SessionRef, String)
    case newGroup(UUID, [SessionRef])
    case renameGroup(UUID, String)

    var title: String {
        switch self {
        case .renameSession: return tr("Rename Session")
        case .newGroup: return tr("New Group")
        case .renameGroup: return tr("Rename Group")
        }
    }

    var message: String? {
        switch self {
        case .newGroup(_, let refs) where !refs.isEmpty: return tr("The \(refs.count) selected sessions move into this group.")
        case .newGroup: return tr("Groups live on the server (the session's tag) and show on every client.")
        case .renameGroup: return tr("Every session in the group moves to the renamed group.")
        default: return nil
        }
    }

    var placeholder: String {
        switch self {
        case .renameSession: return tr("Title")
        default: return tr("Group name")
        }
    }

    var confirm: String {
        switch self {
        case .newGroup: return tr("Create")
        default: return tr("Save")
        }
    }

    var initial: String {
        switch self {
        case .renameSession(_, let t): return t
        case .renameGroup(_, let n): return n
        case .newGroup: return ""
        }
    }
}

/// In-app drag payloads, carried as plain strings.
enum DragPayload {
    case sessions(UUID, [String])
    case group(UUID, String)
    case other

    init(_ s: String) {
        let parts = s.components(separatedBy: "\n")
        guard parts.count == 3, let server = UUID(uuidString: parts[1]) else { self = .other; return }
        switch parts[0] {
        case "binary-sessions": self = .sessions(server, parts[2].components(separatedBy: ",").filter { !$0.isEmpty })
        case "binary-group": self = .group(server, parts[2])
        default: self = .other
        }
    }

    var string: String {
        switch self {
        case .sessions(let s, let ids): return "binary-sessions\n\(s.uuidString)\n\(ids.joined(separator: ","))"
        case .group(let s, let n): return "binary-group\n\(s.uuidString)\n\(n)"
        case .other: return ""
        }
    }
}
