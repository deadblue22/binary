import SwiftUI

/// The home screen: every server's sessions, organized like the Mac sidebar
/// (pinned, groups spanning servers, then each server's own sessions).
struct SessionListView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(SessionOrganizer.self) private var org
    @Environment(ProjectStore.self) private var projects
    @Environment(\.theme) private var theme
    @AppStorage("usageCollapsed") private var usageCollapsed = false
    @State private var query = ""
    @State private var content = ContentSearch()
    @State private var prompt: ListPrompt?
    @State private var promptText = ""
    @State private var notice: String?
    /// Sessions whose whole subagent list is open.
    @State private var showAllAgents: Set<SessionRef> = []
    @State private var settings = false
    @State private var addingServer = false
    @State private var orderingGroups = false

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var multipleServers: Bool { store.orderedConnections.count > 1 }

    var body: some View {
        let mirrors = MirrorIndex(store.orderedConnections)
        let sections = store.orderedConnections.map {
            SidebarBuilder.build($0, org: org, query: query, starred: projects.starredFolders(on: $0.id), mirrors: mirrors, hits: content.hits(for: $0.id, query: query))
        }
        let merged = SidebarBuilder.merge(sections, org: org)
        List {
            if store.servers.isEmpty {
                WelcomeCard { addingServer = true }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            if let merged { mergedSections(merged) }
            ForEach(sections) { section in
                serverSection(section, mirrors: mirrors, merged: merged != nil)
            }
            usageSection
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 28)
        .scrollContentBackground(.hidden)
        .background(theme.c.sidebar)
        .searchable(text: $query, prompt: tr("Search titles, folders, content, groups"))
        .task(id: query) { await content.run(query, on: store.orderedConnections) }
        .refreshable { await refresh() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.c.sidebar, for: .navigationBar)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if let notice {
                NoticeBar(text: notice) { self.notice = nil }
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if self.notice == notice { self.notice = nil }
                    }
            }
        }
        .sheet(isPresented: $settings) { SettingsSheet() }
        .sheet(isPresented: $orderingGroups) { GroupOrderSheet() }
        .task {
            guard DebugHooks.env["BINARY_SETTINGS"] == "1" else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            settings = true
        }
        .sheet(isPresented: $addingServer) {
            NavigationStack {
                ServerEditor(config: nil, standalone: true) { store.add($0) }
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

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { settings = true } label: {
                Label(tr("Settings"), systemImage: "gearshape")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker(tr("Show"), selection: Binding(get: { org.filter }, set: { org.filter = $0 })) {
                    ForEach(SessionFilter.allCases) { f in Text(f.label).tag(f) }
                }
                Toggle(tr("Ungrouped Sessions by Project"), isOn: Binding(get: { org.grouping == .project }, set: { org.grouping = $0 ? .project : .groups }))
                Picker(tr("Sort"), selection: Binding(get: { org.sort }, set: { org.sort = $0 })) {
                    ForEach(SessionSort.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.menu)
                if multipleServers {
                    Toggle(tr("Show Copies from Other Servers"), isOn: Binding(get: { org.showMirrors }, set: { org.showMirrors = $0 }))
                }
                Divider()
                if let first = store.orderedConnections.first {
                    Button(tr("New Group…")) { ask(.newGroup(first.id, [])) }
                }
                Button(tr("Group Order…")) { orderingGroups = true }
                    .disabled(store.orderedConnections.allSatisfy { $0.groupNames.isEmpty } && org.groupOrder.isEmpty)
            } label: {
                Label(tr("Show and Sort"), systemImage: org.filter == .recent && org.sort == .updated && org.grouping == .groups
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            Button { nav.newSession() } label: {
                Label(tr("New Session"), systemImage: "square.and.pencil")
            }
            .disabled(store.servers.isEmpty)
        }
    }

    // MARK: Pinned and groups (all servers)

    @ViewBuilder
    private func mergedSections(_ merged: MergedSidebar) -> some View {
        if !merged.pinned.isEmpty {
            Section(isExpanded: Binding(get: { !org.pinnedCollapsed }, set: { org.pinnedCollapsed = !$0 })) {
                ForEach(merged.pinned) { p in
                    // The header says they're pinned; the row's pin would only take room.
                    var n = p.node
                    let _ = (n.pinned = false)
                    tree(n, conn: p.conn, serverTag: serverTag(p.conn))
                }
            } header: {
                SectionTitle(icon: "pin.fill", title: tr("Pinned"), count: merged.pinned.count,
                             expanded: !org.pinnedCollapsed) {
                    withAnimation(.easeOut(duration: 0.15)) { org.pinnedCollapsed.toggle() }
                }
            }
        }
        ForEach(merged.groups) { g in
            Section(isExpanded: Binding(get: { !org.isCollapsed(g.name) }, set: { if $0 == org.isCollapsed(g.name) { org.toggleCollapsed(g.name) } })) {
                if g.items.isEmpty {
                    EmptyLine(text: tr("Use Move to Group on a session (long press) to add it here"))
                }
                ForEach(g.items) { p in
                    tree(p.node, conn: p.conn, serverTag: serverTag(p.conn))
                }
            } header: {
                SectionTitle(icon: "folder", title: g.name, count: g.items.count, expanded: !g.collapsed) {
                    withAnimation(.easeOut(duration: 0.15)) { org.toggleCollapsed(g.name) }
                } menu: {
                    groupMenu(g, merged)
                }
            }
        }
    }

    /// + on a group: a new session in it, starting from the folder of its latest session.
    private func newSession(in g: MergedGroup) {
        nav.newSession(group: g.name, template: g.items.max { $0.node.session.updatedAt < $1.node.session.updatedAt }?.node.ref)
    }

    @ViewBuilder
    private func groupMenu(_ g: MergedGroup, _ merged: MergedSidebar) -> some View {
        let order = merged.groupNames
        let i = order.firstIndex(of: g.name) ?? 0
        let any = store.orderedConnections.first?.id ?? UUID()
        Button { newSession(in: g) } label: { Label(tr("New Session in Group"), systemImage: "square.and.pencil") }
        Divider()
        Button { ask(.renameGroup(any, g.name)) } label: { Label(tr("Rename Group…"), systemImage: "pencil") }
        Button { reorderGroups(order, g.name, to: i - 1) } label: { Label(tr("Move Up"), systemImage: "arrow.up") }
            .disabled(i == 0)
        Button { reorderGroups(order, g.name, to: i + 1) } label: { Label(tr("Move Down"), systemImage: "arrow.down") }
            .disabled(i >= order.count - 1)
        Button { orderingGroups = true } label: { Label(tr("Group Order…"), systemImage: "arrow.up.arrow.down") }
        Divider()
        Button { ask(.newGroup(any, [])) } label: { Label(tr("New Group…"), systemImage: "folder.badge.plus") }
        Button(role: .destructive) { dissolveEverywhere(g.name) } label: { Label(tr("Ungroup"), systemImage: "folder.badge.minus") }
    }

    // MARK: Servers

    @ViewBuilder
    private func serverSection(_ section: SidebarSection, mirrors: MirrorIndex, merged: Bool) -> some View {
        let conn = section.conn
        let all = store.orderedConnections.map(\.id)
        let hiddenMirrors = org.showMirrors ? [] : mirrors.hidden(on: conn.id)
        // Search shows matches even in folded servers, without unfolding them.
        let expanded = section.flat != nil && searching ? true : !org.isServerCollapsed(conn.id)
        Section(isExpanded: Binding(get: { expanded }, set: { org.setServerCollapsed(conn.id, !$0) })) {
            if let flat = section.flat {
                if flat.isEmpty {
                    EmptyLine(text: searching ? tr("No matches") : tr("No archived sessions"))
                }
                ForEach(flat) { n in tree(n, conn: conn) }
            } else {
                if !merged {
                    ForEach(section.pinned) { n in tree(n, conn: conn) }
                    ForEach(section.groups) { g in
                        ForEach(g.nodes) { n in tree(n, conn: conn) }
                    }
                }
                // Sessions outside starred projects come first, so they don't
                // read as part of the last project.
                ForEach(section.ungrouped) { n in tree(n, conn: conn) }
                ForEach(section.projects) { p in projectRows(p, conn: conn) }
                if (merged ? section.ungrouped.isEmpty && section.projects.isEmpty : section.isEmpty), conn.status == .online {
                    EmptyLine(text: org.filter == .recent ? tr("No activity in the last 3 days") : tr("No sessions"))
                }
            }
            if !hiddenMirrors.isEmpty {
                let hosts = Set(hiddenMirrors.compactMap { mirrors.target[conn.id]?[$0] }).compactMap { store.connection($0)?.displayName }.sorted()
                Button { org.showMirrors = true } label: {
                    Text(tr("\(hiddenMirrors.count) copies hidden (they run on \(hosts.joined(separator: ", "))) · Show"))
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.c.textFaint)
                }
                .compactRow()
            }
        } header: {
            ServerSectionHeader(conn: conn, hidden: hiddenMirrors, expanded: expanded, onToggle: {
                withAnimation(.easeOut(duration: 0.15)) { org.setServerCollapsed(conn.id, expanded) }
            }) {
                Button { conn.reconnect() } label: { Label(tr("Reconnect"), systemImage: "arrow.clockwise") }
                Button { ask(.newGroup(conn.id, [])) } label: { Label(tr("New Group…"), systemImage: "folder.badge.plus") }
                if all.count > 1 {
                    Divider()
                    Button { org.collapseOthers(conn.id, among: all) } label: { Label(tr("Collapse Others"), systemImage: "rectangle.compress.vertical") }
                    Button { org.expandAll(all) } label: { Label(tr("Expand All"), systemImage: "rectangle.expand.vertical") }
                }
            }
        }
    }

    /// A project inside its server's section (lists don't nest sections):
    /// a folding title row, then its sessions.
    @ViewBuilder
    private func projectRows(_ p: ProjectGroup, conn: ServerConnection) -> some View {
        let toggle = { withAnimation(.easeOut(duration: 0.15)) { org.setProjectCollapsed(p.id, !p.collapsed) } }
        SectionTitle(icon: "folder", title: p.name, count: p.nodes.count, expanded: !p.collapsed, onToggle: toggle) {
            Button { newSession(in: p) } label: { Label(tr("New Session in Project"), systemImage: "square.and.pencil") }
            if !p.folder.isEmpty {
                Button { copy(p.folder) } label: { Label(tr("Copy Path"), systemImage: "doc.on.doc") }
            }
            Divider()
            Button {
                let refs = p.allSessions(on: conn)
                org.setArchived(refs, true)
                notice = tr("Archived \(refs.count) sessions of \(p.name). Show → Archived lists them.")
            } label: { Label(tr("Archive Project's Sessions"), systemImage: "archivebox") }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        if !p.collapsed {
            ForEach(p.nodes) { n in tree(n, conn: conn) }
        }
    }

    /// A project's New Session: in its folder.
    private func newSession(in p: ProjectGroup) {
        let latest = p.nodes.max { $0.session.updatedAt < $1.session.updatedAt }?.ref
        nav.newSession(template: latest, folder: p.folder.isEmpty ? nil : p.folder)
    }

    /// Server names on rows only when there is more than one server.
    private func serverTag(_ conn: ServerConnection) -> String? {
        multipleServers ? conn.displayName : nil
    }

    // MARK: Rows

    /// A session row plus, when expanded, its child sessions and subagents.
    private func tree(_ n: SidebarNode, conn: ServerConnection, depth: Int = 0, serverTag: String? = nil) -> AnyView {
        let expanded = org.isExpanded(n.ref)
        let allAgents = conn.subagents[n.session.id] ?? []
        let agents = SidebarBuilder.shownAgents(allAgents, showAll: showAllAgents.contains(n.ref))
        let canToggle = allAgents.count > SidebarBuilder.agentPreview + 1
        let expandable = !n.children.isEmpty || (n.session.subagentCount ?? 0) > 0 || !allAgents.isEmpty
        return AnyView(Group {
            SessionListRow(node: n, depth: depth, expandable: expandable, expanded: expanded,
                           viewOnly: conn.isViewOnly(n.session), serverTag: serverTag,
                           onOpen: { nav.selection = n.ref },
                           onToggle: { withAnimation(.easeOut(duration: 0.15)) { org.setExpanded(n.ref, !expanded) } })
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    let pinned = org.isPinned(n.ref)
                    Button { org.setPinned([n.ref], !pinned) } label: {
                        Label(pinned ? tr("Unpin") : tr("Pin"), systemImage: pinned ? "pin.slash" : "pin")
                    }
                    .tint(theme.c.warning)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    let archived = org.isArchived(n.ref)
                    Button { org.setArchived([n.ref], !archived) } label: {
                        Label(archived ? tr("Unarchive") : tr("Archive"), systemImage: archived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .tint(theme.c.textMuted)
                }
                .contextMenu { sessionMenu(n, conn) }
                .sessionRow(state: n.session.shownState, live: n.session.live, background: n.session.hasBackgroundWork, bottomSeparator: n.hit == nil)
                .task(id: expanded && (n.session.subagentCount ?? 0) > 0 ? "\(n.session.id)|\(n.session.updatedAt.timeIntervalSince1970)" : "") {
                    guard expanded, (n.session.subagentCount ?? 0) > 0 else { return }
                    await conn.loadSubagents(n.session.id)
                }
            if let hit = n.hit {
                ForEach(hit.snippets.prefix(2), id: \.uuid) { sn in
                    SnippetListRow(snippet: sn, query: query, depth: depth) { nav.open(n.ref, at: sn.uuid) }
                        .compactRow()
                }
            }
            if expanded && expandable {
                ForEach(n.children) { c in
                    tree(c, conn: conn, depth: depth + 1)
                }
                ForEach(agents) { a in
                    SubagentListRow(info: a, depth: depth + 1) {
                        nav.selection = SessionRef(server: conn.id, session: n.session.id, agent: a.id)
                    }
                    .contextMenu {
                        Button { copy(a.id) } label: { Label(tr("Copy Subagent ID"), systemImage: "doc.on.doc") }
                    }
                    .sessionRow(state: a.running == true ? .running : nil)
                }
                if canToggle {
                    Button {
                        if agents.count < allAgents.count { showAllAgents.insert(n.ref) } else { showAllAgents.remove(n.ref) }
                    } label: {
                        Text(agents.count < allAgents.count
                             ? tr("Show all \(allAgents.count) subagents")
                             : tr("Show only the latest \(SidebarBuilder.agentPreview)"))
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.c.focus)
                            .padding(.leading, SessionListRow.indent(depth + 1) + 4)
                    }
                    .compactRow()
                }
                if allAgents.isEmpty && n.children.isEmpty {
                    Text(conn.supportsSubagents ? tr("Loading subagents…") : tr("This server can't list subagents"))
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.c.textFaint)
                        .padding(.leading, SessionListRow.indent(depth + 1) + 4)
                        .compactRow()
                }
            }
        })
    }

    @ViewBuilder
    private func sessionMenu(_ n: SidebarNode, _ conn: ServerConnection) -> some View {
        let s = n.session
        let pinned = org.isPinned(n.ref)
        Button { org.setPinned([n.ref], !pinned) } label: {
            Label(pinned ? tr("Unpin") : tr("Pin"), systemImage: pinned ? "pin.slash" : "pin")
        }
        Menu {
            let groups = org.orderedGroups(inUse: store.orderedConnections.reduce(into: Set<String>()) { $0.formUnion($1.groupNames) })
            ForEach(groups, id: \.self) { g in
                Button { move([n.ref], to: g) } label: {
                    if s.group == g { Label(g, systemImage: "checkmark") } else { Text(g) }
                }
                .disabled(s.group == g)
            }
            if !groups.isEmpty { Divider() }
            Button(tr("New Group…")) { ask(.newGroup(conn.id, [n.ref])) }
            if s.group != nil {
                Button(tr("Remove from Group")) { move([n.ref], to: "") }
            }
        } label: {
            Label(tr("Move to Group"), systemImage: "folder")
        }
        let archived = org.isArchived(n.ref)
        Button { org.setArchived([n.ref], !archived) } label: {
            Label(archived ? tr("Unarchive") : tr("Archive"), systemImage: archived ? "tray.and.arrow.up" : "archivebox")
        }
        Divider()
        Button { ask(.renameSession(n.ref, s.title)) } label: { Label(tr("Rename…"), systemImage: "pencil") }
        Button { nav.newChildSession(of: n.ref) } label: { Label(tr("New Child Session"), systemImage: "plus.bubble") }
        Button { copy(s.id) } label: { Label(tr("Copy Session ID"), systemImage: "number") }
        Button { copy(s.resumeCommand) } label: { Label(tr("Copy Resume Command"), systemImage: "terminal") }
        Button { copy(s.cwd) } label: { Label(tr("Copy Working Directory"), systemImage: "folder") }
        if s.live {
            Divider()
            Button(role: .destructive) {
                Task {
                    do { try await conn.stop(s.id) } catch { notice = error.localizedDescription }
                }
            } label: { Label(tr("Stop Process"), systemImage: "stop.circle") }
        }
    }

    // MARK: Plan usage

    @ViewBuilder
    private var usageSection: some View {
        let conns = store.orderedConnections.filter { $0.usage?.available == true }
        if !conns.isEmpty {
            Section(isExpanded: Binding(get: { !usageCollapsed }, set: { usageCollapsed = !$0 })) {
                ForEach(conns) { c in
                    if let u = c.usage {
                        VStack(alignment: .leading, spacing: 6) {
                            if conns.count > 1 {
                                Text(c.displayName)
                                    .font(theme.font(.caption).weight(.semibold))
                                    .foregroundStyle(theme.c.textMuted)
                            }
                            ForEach(u.windows, id: \.kind) { w in
                                PlanWindowRow(label: Format.planWindowName(w.kind), window: w, showReset: true)
                            }
                        }
                        .padding(.vertical, 2)
                        .compactRow()
                    }
                }
            } header: {
                SectionTitle(icon: "chart.bar.xaxis", title: tr("Plan Usage"), count: nil, expanded: !usageCollapsed) {
                    withAnimation(.easeOut(duration: 0.15)) { usageCollapsed.toggle() }
                }
            }
        }
    }

    // MARK: Actions

    private func refresh() async {
        for c in store.orderedConnections { c.reconnect() }
        // The list fills in as the streams come back; give them a moment.
        try? await Task.sleep(nanoseconds: 800_000_000)
        for c in store.orderedConnections { await c.refreshUsage(force: true) }
    }

    private func ask(_ p: ListPrompt) {
        promptText = p.initial
        prompt = p
    }

    private func commit(_ p: ListPrompt, _ text: String) {
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

    private func dissolveEverywhere(_ name: String) {
        for conn in store.orderedConnections where conn.groupNames.contains(name) {
            let ids = conn.sessions.values.filter { $0.group == name }.map(\.id)
            Task {
                do { try await conn.setGroup(ids, "") } catch { notice = error.localizedDescription }
            }
        }
        org.removeGroup(name)
    }

    private func reorderGroups(_ order: [String], _ name: String, to index: Int) {
        var o = order
        guard let i = o.firstIndex(of: name), index >= 0, index < o.count else { return }
        o.remove(at: i)
        o.insert(name, at: index)
        org.setGroupOrder(o + org.groupOrder.filter { !o.contains($0) })
    }
}

/// What the rename and new-group alerts ask for.
enum ListPrompt {
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
