import SwiftUI

/// A blank session in the detail column. It starts in the project the last
/// session was started in, with the settings last used there; the bar under
/// the message box changes either until the first message is sent, which
/// creates the session.
struct NewSessionView: View {
    let draft: NewSessionDraft
    @Environment(ServerStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(SessionOrganizer.self) private var org
    @Environment(ProjectStore.self) private var projects
    @Environment(\.theme) private var theme

    @State private var target: StartTarget?
    @State private var config = StartConfig()
    @State private var git: GitInfo?
    @State private var parent: SessionRef?
    @State private var group = ""
    @State private var text = ""
    @State private var images: [PendingImage] = []
    @State private var creating = false
    @State private var error: String?
    @State private var picking = false
    @State private var browsing = false
    @State private var editing: EditRequest?
    @State private var paste = PasteCatcher()
    @State private var dropTarget = false
    @State private var composing = false
    @State private var composingWatcher = ComposingWatcher()
    @FocusState private var focused: Bool

    private struct EditRequest: Identifiable {
        let project: Project
        let isNew: Bool
        var id: UUID { project.id }
    }

    private var conn: ServerConnection? { target.flatMap { store.connection($0.server) } }
    private var project: Project? { projects.project(target?.project) }
    private var folder: String { target?.folder ?? "" }
    private var parentSummary: SessionSummary? {
        guard let parent, parent.server == target?.server else { return nil }
        return conn?.sessions[parent.session]
    }
    private var isRepo: Bool { git?.isRepo == true }
    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
            && !creating && !folder.isEmpty && conn?.status == .online
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .fillAvailable()
        .background(theme.c.background)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.c.focus, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(theme.c.focus.opacity(0.06))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .imageDrop(isTargeted: $dropTarget) { add($0) }
        .background {
            // ⌥⌘1…9 pick starred projects, ⌥⌘0 adds one, without opening the list.
            ForEach(0..<min(9, projects.favorites.count), id: \.self) { i in
                Button("") { choose(projects.favorites[i]) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                    .hidden()
            }
            Button("") { newProject() }.keyboardShortcut("0", modifiers: [.command, .option]).hidden()
        }
        .navigationTitle(parent == nil ? tr("New Session") : tr("New Child Session"))
        #if os(macOS)
        .navigationSubtitle(conn?.displayName ?? "")
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: setUp)
        .onDisappear { paste.remove(); composingWatcher.remove() }
        .onChange(of: focused) { _, f in paste.active = f }
        .onChange(of: text) { _, _ in composing = focused && ComposingWatcher.composing() }
        .onChange(of: nav.effortStep) { _, step in stepEffort(step.delta) }
        .task(id: target) { await loadGit() }
        .task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !Task.isCancelled { focused = true }
        }
        .sheet(isPresented: $browsing) {
            if let c = conn ?? store.orderedConnections.first {
                DirectoryBrowser(conn: c, initial: folder.isEmpty ? "~" : folder) { path in
                    pickFolder(server: c.id, path)
                }
            }
        }
        .sheet(item: $editing) { req in
            ProjectEditor(draft: req.project, isNew: req.isNew, onSave: { p in
                projects.save(p)
                // Editing the open project's defaults applies them here too.
                if req.isNew || target?.project == p.id { choose(p) }
            }, onDelete: req.isNew ? nil : {
                projects.delete(req.project.id)
                if target?.project == req.project.id { target?.project = nil }
            })
        }
    }

    // MARK: Empty state

    private var header: some View {
        VStack(spacing: 10) {
            IconTile(icon: parent == nil ? "square.and.pencil" : "plus.bubble", tint: theme.c.focus, size: 46)
            Text(project?.name ?? (folder.isEmpty ? tr("New Session") : Project.defaultName(for: folder)))
                .font(theme.font(.title))
                .foregroundStyle(theme.c.heading)
            if !folder.isEmpty {
                Text(Format.path(folder, cwd: nil))
                    .font(theme.mono(theme.size(.caption)))
                    .foregroundStyle(theme.c.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            if let p = parentSummary {
                RemovableChip(icon: "arrow.turn.down.right", text: tr("Child of \(p.title)")) { parent = nil }
                    .help(tr("Start an independent session instead"))
            }
            if let c = conn, case .offline(let m) = c.status {
                Label(tr("Server offline: \(m)"), systemImage: "wifi.slash")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.warning)
            }
        }
        .padding(.horizontal, theme.gutter)
    }

    // MARK: Composer

    private var composer: some View {
        let shape = RoundedRectangle(cornerRadius: theme.isPrimary ? 10 : 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 7) {
            if let error {
                Label(error, systemImage: "xmark.octagon")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.danger)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if !images.isEmpty { AttachmentStrip(images: $images) }
            HStack(alignment: .bottom, spacing: 8) {
                AttachButton { add($0) }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty && !composing {
                        theme.placeholder(folder.isEmpty ? tr("Choose a project below first…") : tr("What should Claude do?"))
                            .font(theme.font(.body))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.c.text)
                        .lineSpacing(theme.lineSpacing * 0.6)
                        .lineLimit(1...12)
                        .focused($focused)
                        .onSubmit(create)
                        .shiftReturnNewline(when: focused)
                }
                .padding(.vertical, 5)
                Button(action: create) {
                    Group {
                        if creating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                        }
                    }
                    .frame(width: theme.sendButton, height: theme.sendButton)
                    .background(Circle().fill(canSend ? theme.c.accent : theme.c.border))
                    .foregroundStyle(canSend ? theme.c.onAccent : theme.c.textFaint)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(tr("Start the session (↩)"))
                .accessibilityLabel(tr("Start the session"))
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(shape.fill(theme.c.input))
            .overlay(shape.strokeBorder(focused ? theme.c.focus.opacity(0.8) : theme.c.border, lineWidth: focused ? 1.5 : 1))
            .shadow(color: theme.c.shadow, radius: focused ? 8 : 4, y: 2)
            .contentShape(shape)
            .onTapGesture { focused = true }
            controls
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: theme.readingWidth)
        .frame(maxWidth: .infinity)
        .background(theme.c.background)
    }

    // MARK: Controls

    private var controls: some View {
        #if os(macOS)
        ViewThatFits(in: .horizontal) {
            controlBar(text: true)
            controlBar(text: false)
        }
        .lineLimit(1)
        #else
        // A phone is too narrow for every setting with its value: scroll.
        ScrollView(.horizontal) {
            controlBar(text: true)
                .lineLimit(1)
        }
        .scrollIndicators(.never)
        #endif
    }

    private func controlBar(text showText: Bool) -> some View {
        HStack(spacing: 4) {
            projectButton
            if isRepo { branchMenu(showText) }
            if !group.isEmpty || !(conn.map { org.orderedGroups($0.id, inUse: $0.groupNames) } ?? []).isEmpty {
                groupMenu(showText)
            }
            Spacer(minLength: 8)
            modeMenu(showText)
            modelMenu(showText)
            effortMenu(showText)
        }
    }

    private var projectButton: some View {
        Button { picking = true } label: {
            ControlLabel(icon: config.worktree ? "square.stack.3d.up" : (project != nil ? "folder.fill" : "folder"),
                         text: project?.name ?? (folder.isEmpty ? tr("Choose a project…") : Project.defaultName(for: folder)),
                         note: store.orderedConnections.count > 1 ? conn?.displayName : nil)
        }
        .buttonStyle(.plain)
        .help(tr("Project (⌥⌘1…9 for starred ones)"))
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            ProjectPicker(current: target, onPick: { t in
                picking = false
                if let p = projects.project(t.project) { choose(p) } else { pickFolder(server: t.server, t.folder) }
            }, onNew: {
                picking = false
                newProject()
            }, onEdit: { p in
                picking = false
                editing = EditRequest(project: p, isNew: false)
            }, onEditFolder: { server, path in
                picking = false
                var p = Project(name: Project.defaultName(for: path), server: server, folder: path)
                p.startConfig = projects.config(for: StartTarget(server: server, folder: path, project: nil))
                editing = EditRequest(project: p, isNew: true)
            }, onBrowse: {
                picking = false
                browsing = true
            })
            .environment(store)
            .environment(projects)
            .environment(\.theme, theme)
        }
    }

    private func branchMenu(_ showText: Bool) -> some View {
        let base = config.branch ?? git?.current ?? "HEAD"
        return Menu {
            Picker(tr("Start From"), selection: Binding(get: { config.branch ?? "" }, set: { config.branch = $0.isEmpty ? nil : $0 })) {
                Text(tr("Current") + (git?.current.map { " (\($0))" } ?? "")).tag("")
                ForEach(git?.pickerBranches(keeping: config.branch) ?? [], id: \.self) { b in Text(b).tag(b) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(tr("New Worktree for Each Session"), isOn: $config.worktree)
        } label: {
            ControlLabel(icon: config.worktree ? "square.stack.3d.up" : "arrow.triangle.branch",
                         text: config.worktree ? "worktree · \(base)" : base, showText: showText,
                         tint: switchesDirtyFolder ? theme.c.warning : nil)
        }
        .plainMenu()
        .help(branchHelp)
    }

    private var switchesDirtyFolder: Bool {
        !config.worktree && config.branch != nil && config.branch != git?.current && git?.dirty == true
    }

    private var branchHelp: String {
        if config.worktree {
            return tr("A new worktree under .claude/worktrees on branch claude/<name>, cut from \(config.branch ?? git?.current ?? "HEAD")")
        }
        if let b = config.branch, b != git?.current {
            let dirty = git?.dirty == true ? tr(" (it has uncommitted changes)") : ""
            return tr("Switches the folder to \(b)\(dirty)")
        }
        return tr("Works in the folder itself")
    }

    private func groupMenu(_ showText: Bool) -> some View {
        Menu {
            Picker(tr("Group"), selection: $group) {
                Text(tr("None")).tag("")
                if let conn {
                    ForEach(org.orderedGroups(conn.id, inUse: conn.groupNames), id: \.self) { g in Text(g).tag(g) }
                }
            }
            .pickerStyle(.inline)
        } label: {
            ControlLabel(icon: "tag", text: group.isEmpty ? tr("No Group") : group, showText: showText)
        }
        .plainMenu()
        .help(tr("Group"))
    }

    private func modeMenu(_ showText: Bool) -> some View {
        let mode = effectiveMode
        let risky = mode == "bypassPermissions"
        return Menu {
            Picker(tr("Permission Mode"), selection: Binding(get: { mode }, set: { config.permissionMode = $0 })) {
                ForEach(conn?.info?.permissionModes ?? Format.modeKeys, id: \.self) { m in Text(Format.mode(m)).tag(m) }
            }
            .pickerStyle(.inline)
        } label: {
            ControlLabel(icon: risky ? "exclamationmark.shield" : "lock.shield", text: Format.mode(mode),
                         showText: showText, tint: risky ? theme.c.warning : nil)
        }
        .plainMenu()
        .help(tr("Permission mode"))
    }

    private func modelMenu(_ showText: Bool) -> some View {
        let models = (conn?.info?.models ?? []).filter { $0.value != "default" }
        let name = models.first { $0.value == config.model }?.displayName ?? (config.model.isEmpty ? tr("Default") : config.model)
        return Menu {
            Picker(tr("Model"), selection: $config.model) {
                Text(tr("Default")).tag("")
                ForEach(models) { m in Text(m.displayName).tag(m.value) }
                if !config.model.isEmpty, !models.contains(where: { $0.value == config.model }) {
                    Text(config.model).tag(config.model)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ControlLabel(icon: "cpu", text: name, showText: showText)
        }
        .plainMenu()
        .help(tr("Model"))
    }

    private var effortLevels: [String] { conn?.effortLevels(for: config.model.isEmpty ? nil : config.model) ?? [] }

    private func effortMenu(_ showText: Bool) -> some View {
        Menu {
            Picker("Effort", selection: $config.effort) {
                Text(tr("Default")).tag("")
                ForEach(effortLevels, id: \.self) { l in Text(Format.effort(l)).tag(l) }
            }
            .pickerStyle(.inline)
        } label: {
            ControlLabel(icon: "gauge.with.dots.needle.50percent",
                         text: config.effort.isEmpty ? tr("Default") : Format.effort(config.effort), showText: showText)
        }
        .plainMenu()
        .help(tr("Effort (⌘[ / ⌘] to step)"))
    }

    private var effectiveMode: String {
        config.permissionMode.isEmpty ? (conn?.info?.defaultPermissionMode ?? "default") : config.permissionMode
    }

    private func stepEffort(_ d: Int) {
        let steps = [""] + effortLevels
        let i = steps.firstIndex(of: config.effort) ?? 0
        config.effort = steps[max(0, min(steps.count - 1, i + d))]
    }

    // MARK: Setup

    private func setUp() {
        paste.onImages = { add($0) }
        paste.install()
        paste.active = true
        composingWatcher.install { composing = focused && $0 }
        parent = draft.parent
        group = draft.group ?? ""
        if let r = draft.parent, let p = store.connection(r.server)?.sessions[r.session] {
            pick(server: r.server, p.cwd)
            group = p.group ?? group
        } else if let t = draft.template, let ts = store.connection(t.server)?.sessions[t.session] {
            // A group's +: the folder of its latest session; a project's: the project's.
            pick(server: t.server, draft.folder ?? ts.cwd)
        } else if let last = projects.lastTarget, store.connection(last.server) != nil {
            if let p = projects.project(last.project) { choose(p) } else { pickFolder(server: last.server, last.folder) }
        } else if let p = store.orderedConnections.lazy.compactMap({ c in self.projects.projects(on: c.id).first }).first {
            choose(p)
        } else if let latest = store.orderedConnections.lazy.compactMap({ c in
            c.sessions.values.filter { !c.isViewOnly($0) }.max { $0.updatedAt < $1.updatedAt }.map { (c.id, $0.cwd) }
        }).first {
            // Nothing started from this client yet: the folder of the latest session.
            pick(server: latest.0, latest.1)
        }
        if DebugHooks.env["BINARY_PROJECT_PICKER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { picking = true }
        }
        if let what = DebugHooks.env["BINARY_EDIT_PROJECT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if what == "new" { newProject() } else if let p = project ?? projects.projects.first { editing = EditRequest(project: p, isNew: false) }
            }
        }
    }

    private func pick(server: UUID, _ path: String) {
        if let proj = projects.project(server: server, folder: path) { choose(proj) } else { pickFolder(server: server, path) }
    }

    private func choose(_ p: Project) {
        target = StartTarget(server: p.server, folder: p.folder, project: p.id)
        config = p.startConfig
    }

    private func pickFolder(server: UUID, _ path: String) {
        if let p = projects.project(server: server, folder: path) { return choose(p) }
        let t = StartTarget(server: server, folder: path, project: nil)
        target = t
        config = projects.config(for: t)
    }

    private func newProject() {
        let s = target?.server ?? store.orderedConnections.first?.id ?? UUID()
        var p = Project(name: folder.isEmpty ? "" : Project.defaultName(for: folder), server: s, folder: folder)
        p.startConfig = config
        editing = EditRequest(project: p, isNew: true)
    }

    private func add(_ new: [PendingImage]) {
        let room = ImageProcessor.maxPerMessage - images.count
        images += new.prefix(max(room, 0))
    }

    private func loadGit() async {
        guard let conn, !folder.isEmpty else { git = nil; return }
        let info = await conn.gitInfo(folder)
        guard !Task.isCancelled else { return }
        git = info
    }

    // MARK: Create

    private func create() {
        guard canSend, let conn, let target else { return }
        creating = true
        error = nil
        // Branch and worktree only mean something in a repository.
        var used = config
        if !isRepo { used.branch = nil; used.worktree = false }
        let switchBranch = used.branch.flatMap { $0 == git?.current && !used.worktree ? nil : $0 }
        let env = project?.envDictionary ?? [:]
        let req = CreateSessionRequest(
            cwd: target.folder,
            prompt: text.trimmingCharacters(in: .whitespacesAndNewlines),
            model: used.model,
            effort: used.effort,
            permissionMode: effectiveMode,
            title: "",
            parentId: parentSummary?.id,
            tag: group.isEmpty ? nil : group,
            branch: switchBranch,
            worktree: used.worktree ? true : nil,
            env: env.isEmpty ? nil : env,
            images: images.isEmpty ? nil : images.map(\.wire)
        )
        let group = group
        Task {
            do {
                let s = try await conn.create(req)
                if !group.isEmpty { org.addGroup(conn.id, group) }
                projects.remember(target, used)
                nav.selection = SessionRef(server: conn.id, session: s.id)
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}

/// A small removable label.
private struct RemovableChip: View {
    let icon: String
    let text: String
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 18))
        }
        .font(theme.font(.caption))
        .foregroundStyle(theme.c.textMuted)
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.c.surfaceAlt))
        .overlay(Capsule().strokeBorder(theme.c.border))
    }
}
