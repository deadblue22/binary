import SwiftUI

// MARK: - Picker

/// The project list in the New Session sheet, after Claude desktop's
/// environment picker: search, starred (⌥⌘1…9), per-server projects and
/// recent folders, and "New Project…" (⌥⌘0).
struct ProjectPicker: View {
    let current: StartTarget?
    let onPick: (StartTarget) -> Void
    let onNew: () -> Void
    let onEdit: (Project) -> Void
    /// The options button on a plain folder: save it as a project with its settings.
    var onEditFolder: ((UUID, String) -> Void)? = nil
    var onBrowse: (() -> Void)? = nil
    @Environment(ServerStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var recent: [UUID: [String]] = [:]
    @FocusState private var searchFocused: Bool

    private var q: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ name: String, _ folder: String) -> Bool {
        q.isEmpty || name.lowercased().contains(q) || folder.lowercased().contains(q)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.c.textFaint)
                PlainField(placeholder: tr("Search projects and folders…"), text: $query, focus: $searchFocused)
                    .foregroundStyle(theme.c.text)
            }
            .font(theme.font(.callout))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(theme.c.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let favs = projects.favorites.filter { matches($0.name, $0.folder) }
                    if !favs.isEmpty {
                        header(tr("Starred"))
                        ForEach(Array(favs.enumerated()), id: \.element.id) { i, p in
                            projectRow(p, shortcut: i < 9 ? i + 1 : nil)
                        }
                        divider
                    }
                    ForEach(store.orderedConnections) { conn in
                        let own = projects.projects(on: conn.id).filter { !$0.starred && matches($0.name, $0.folder) }
                        let known = Set(projects.projects(on: conn.id).map(\.folder))
                        let dirs = (recent[conn.id] ?? []).filter { !known.contains($0) && matches(Project.defaultName(for: $0), $0) }
                        if !own.isEmpty || !dirs.isEmpty {
                            header(conn.displayName, icon: "server.rack")
                            ForEach(own) { p in projectRow(p, shortcut: nil) }
                            ForEach(dirs, id: \.self) { d in folderRow(conn.id, d) }
                            divider
                        }
                    }
                    if projects.projects.isEmpty && recent.values.allSatisfy(\.isEmpty) {
                        Text(tr("No projects yet. Add one below, or pick a folder."))
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.c.textFaint)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
                .slimScrollers()
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(theme.c.border).frame(height: 1)
            VStack(spacing: 0) {
                if let onBrowse {
                    PickerRow(icon: "folder.badge.plus", title: tr("Open Folder…"), action: onBrowse)
                }
                PickerRow(icon: "plus", title: tr("New Project…"), shortcut: "⌥⌘0", action: onNew)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 400)
        .background(theme.c.surface)
        .background {
            // ⌥⌘1…9 for starred projects, ⌥⌘0 for a new one, while the list is open.
            ForEach(0..<min(9, projects.favorites.count), id: \.self) { i in
                Button("") { pick(projects.favorites[i]) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                    .hidden()
            }
            Button("", action: onNew).keyboardShortcut("0", modifiers: [.command, .option]).hidden()
        }
        .onAppear { searchFocused = true }
        .task {
            for conn in store.orderedConnections where conn.status == .online {
                recent[conn.id] = (try? await conn.recentDirs()) ?? []
            }
        }
    }

    private func pick(_ p: Project) {
        onPick(StartTarget(server: p.server, folder: p.folder, project: p.id))
    }

    private func header(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: theme.size(.small))) }
            Text(text)
        }
        .font(theme.font(.caption).weight(.medium))
        .foregroundStyle(theme.c.textFaint)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private var divider: some View {
        Rectangle().fill(theme.c.border).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func projectRow(_ p: Project, shortcut: Int?) -> some View {
        PickerRow(icon: p.worktree ? "square.stack.3d.up" : "folder",
                  title: p.name,
                  subtitle: [Format.path(p.folder, cwd: nil), p.branch, p.worktree ? "worktree" : nil].compactMap { $0 }.joined(separator: " · "),
                  shortcut: shortcut.map { "⌥⌘\($0)" },
                  checked: current?.project == p.id,
                  starred: p.starred,
                  onStar: { projects.setStarred(p.id, !p.starred) },
                  onEdit: { onEdit(p) }) {
            pick(p)
        }
    }

    private func folderRow(_ server: UUID, _ folder: String) -> some View {
        PickerRow(icon: "clock",
                  title: Project.defaultName(for: folder),
                  subtitle: Format.path(folder, cwd: nil),
                  checked: current?.project == nil && current?.folder == folder && current?.server == server,
                  starred: false,
                  onStar: {
                      // Starring a recent folder saves it as a project.
                      var p = Project(name: Project.defaultName(for: folder), server: server, folder: folder)
                      p.starred = true
                      projects.save(p)
                  },
                  onEdit: onEditFolder.map { f in { f(server, folder) } }) {
            onPick(StartTarget(server: server, folder: folder, project: nil))
        }
    }
}

struct PickerRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var shortcut: String? = nil
    var checked = false
    var starred: Bool? = nil
    var onStar: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: theme.size(.caption)))
                .foregroundStyle(theme.c.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(theme.font(.callout))
                    .foregroundStyle(theme.c.text)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(theme.font(.small))
                        .foregroundStyle(theme.c.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: theme.size(.caption), weight: .semibold))
                    .foregroundStyle(theme.c.focus)
            }
            if let onEdit, hover {
                Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.icon(size: 22))
                    .help(tr("Project settings and new-session defaults"))
            }
            if let onStar, let starred, hover || starred {
                Button(action: onStar) {
                    Image(systemName: starred ? "star.fill" : "star")
                        .foregroundStyle(starred ? theme.c.warning : theme.c.textFaint)
                }
                .buttonStyle(.icon(size: 22))
                .help(starred ? tr("Unstar") : tr("Star"))
            }
            if let shortcut {
                Text(shortcut)
                    .font(theme.font(.small).monospacedDigit())
                    .foregroundStyle(theme.c.textFaint)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
            .fill(hover ? theme.c.hover : .clear)
            .padding(.horizontal, 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

// MARK: - Editor

/// Create or edit a project: name, folder with branch and worktree, and
/// environment variables (after Claude desktop's "Edit environment").
struct ProjectEditor: View {
    @State var draft: Project
    let isNew: Bool
    let onSave: (Project) -> Void
    var onDelete: (() -> Void)? = nil
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var git: GitInfo?
    @State private var checkingGit = false
    @State private var browsing = false
    @State private var showEnv = DebugHooks.expandTools
    @State private var confirmDelete = false
    @FocusState private var folderFocused: Bool

    private var conn: ServerConnection? { store.connection(draft.server) }
    private var badKeys: [String] { draft.env.map(\.key).filter { !$0.isEmpty && !EnvVar.isValidName($0) } }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.folder.trimmingCharacters(in: .whitespaces).isEmpty && badKeys.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isNew ? tr("New Project") : tr("Edit Project"))
                    .font(theme.font(.title))
                    .foregroundStyle(theme.c.heading)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.icon(size: 26))
                    .keyboardShortcut(.cancelAction)
            }
            labeled(tr("Name")) {
                ThemedField(placeholder: tr("e.g. my-app"), text: $draft.name)
            }
            if store.orderedConnections.count > 1 {
                labeled(tr("Server")) {
                    Picker("", selection: $draft.server) {
                        ForEach(store.orderedConnections) { c in Text(c.displayName).tag(c.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tr("Folder"))
                        .font(theme.font(.callout).weight(.semibold))
                        .foregroundStyle(theme.c.text)
                    Spacer()
                    Button {
                        browsing = true
                    } label: {
                        Label(tr("Browse…"), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.themed(.secondary, compact: true))
                    .disabled(conn?.status != .online)
                }
                folderRow
                gitNote
            }
            defaultsSection
            envSection
            Rectangle().fill(theme.c.border).frame(height: 1).padding(.horizontal, -24)
            HStack {
                if !isNew, onDelete != nil {
                    Button(tr("Delete Project")) { confirmDelete = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.c.danger)
                        .font(theme.font(.callout).weight(.medium))
                }
                Spacer()
                Button(tr("Cancel")) { dismiss() }
                    .buttonStyle(.themed(.secondary))
                Button(tr("Save")) {
                    var p = draft
                    p.name = p.name.trimmingCharacters(in: .whitespaces)
                    p.folder = p.folder.trimmingCharacters(in: .whitespaces)
                    p.env = p.env.filter { !$0.key.isEmpty }
                    onSave(p)
                    dismiss()
                }
                .buttonStyle(.themed(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(theme.c.background)
        .task(id: "\(draft.server)|\(draft.folder)") { await loadGit() }
        .sheet(isPresented: $browsing) {
            if let conn {
                DirectoryBrowser(conn: conn, initial: draft.folder.isEmpty ? "~" : draft.folder) { path in
                    draft.folder = path
                    if draft.name.isEmpty { draft.name = Project.defaultName(for: path) }
                }
            }
        }
        .alert(tr("Delete this project?"), isPresented: $confirmDelete) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Delete"), role: .destructive) {
                onDelete?()
                dismiss()
            }
        } message: {
            Text(tr("Only the saved project is removed; the folder and its sessions stay."))
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(theme.font(.callout).weight(.semibold))
                .foregroundStyle(theme.c.text)
            content()
        }
    }

    private var isRepo: Bool { git?.isRepo == true }

    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(theme.c.textMuted)
            PlainField(placeholder: "/path/to/project", text: $draft.folder, focus: $folderFocused)
                .font(theme.mono(theme.size(.callout) - 1))
                .foregroundStyle(theme.c.text)
            if checkingGit { ProgressView().controlSize(.small) }
            Menu {
                Picker("", selection: Binding(get: { draft.branch ?? "" }, set: { draft.branch = $0.isEmpty ? nil : $0 })) {
                    Text(tr("Current") + (git?.current.map { " (\($0))" } ?? "")).tag("")
                    ForEach(git?.branches ?? [], id: \.self) { b in Text(b).tag(b) }
                }
                .pickerStyle(.inline)
            } label: {
                ControlLabel(icon: "arrow.triangle.branch", text: draft.branch ?? git?.current ?? tr("Branch"))
            }
            .plainMenu()
            .disabled(!isRepo)
            Toggle("Worktree", isOn: $draft.worktree)
                .toggleStyle(.checkbox)
                .font(theme.font(.callout))
                .disabled(!isRepo)
                .help(tr("Start each session in its own worktree under .claude/worktrees"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .card(fill: theme.c.surface, shadow: false)
    }

    @ViewBuilder
    private var gitNote: some View {
        if let git, !draft.folder.isEmpty {
            if !git.isRepo {
                note(tr("Not a git repository: branch and worktree are off."), color: theme.c.textFaint)
            } else if draft.worktree {
                note(tr("Each session gets .claude/worktrees/<name> on branch claude/<name>, cut from \(draft.branch ?? git.current ?? "HEAD")."), color: theme.c.textFaint)
            } else if let b = draft.branch, b != git.current {
                let dirty = git.dirty == true ? tr("; it has uncommitted changes, so that will fail") : ""
                note(tr("Sessions switch the folder to \(b) first\(dirty)."),
                     color: git.dirty == true ? theme.c.warning : theme.c.textFaint)
            }
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What new sessions here start with; starting one updates these.
    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("New sessions"))
                .font(theme.font(.callout).weight(.semibold))
                .foregroundStyle(theme.c.text)
            HStack(spacing: 6) {
                let models = (conn?.info?.models ?? []).filter { $0.value != "default" }
                Menu {
                    Picker(tr("Model"), selection: $draft.model) {
                        Text(tr("Default")).tag("")
                        ForEach(models) { m in Text(m.displayName).tag(m.value) }
                        if !draft.model.isEmpty, !models.contains(where: { $0.value == draft.model }) {
                            Text(draft.model).tag(draft.model)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ControlLabel(icon: "cpu", text: models.first { $0.value == draft.model }?.displayName
                                 ?? (draft.model.isEmpty ? tr("Default") : draft.model), note: tr("Model"))
                }
                .plainMenu()
                Menu {
                    Picker("Effort", selection: $draft.effort) {
                        Text(tr("Default")).tag("")
                        ForEach(conn?.effortLevels(for: draft.model.isEmpty ? nil : draft.model) ?? [], id: \.self) { l in Text(Format.effort(l)).tag(l) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ControlLabel(icon: "gauge.with.dots.needle.50percent",
                                 text: draft.effort.isEmpty ? tr("Default") : Format.effort(draft.effort), note: "Effort")
                }
                .plainMenu()
                Menu {
                    Picker(tr("Permission Mode"), selection: $draft.permissionMode) {
                        Text(tr("Default")).tag("")
                        ForEach(conn?.info?.permissionModes ?? Format.modeKeys, id: \.self) { m in Text(Format.mode(m)).tag(m) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ControlLabel(icon: "lock.shield",
                                 text: draft.permissionMode.isEmpty ? tr("Default") : Format.mode(draft.permissionMode),
                                 note: tr("Permissions"))
                }
                .plainMenu()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .card(fill: theme.c.surface, shadow: false)
            note(tr("Each new session here starts with these, and starting one with other settings updates them."), color: theme.c.textFaint)
        }
    }

    private var envSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showEnv.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Environment variables"))
                            .font(theme.font(.callout).weight(.semibold))
                            .foregroundStyle(theme.c.text)
                        Text(draft.env.isEmpty ? tr("None for this project")
                             : tr("\(draft.env.count) variables"))
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.c.textMuted)
                    }
                    Spacer()
                    Chevron(expanded: showEnv)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showEnv {
                Rectangle().fill(theme.c.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($draft.env) { $v in
                        HStack(spacing: 8) {
                            ThemedField(placeholder: "NAME", text: $v.key)
                                .frame(width: 180)
                            Text("=").foregroundStyle(theme.c.textFaint)
                            ThemedField(placeholder: tr("value"), text: $v.value)
                            Button {
                                draft.env.removeAll { $0.id == v.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.icon(size: 24))
                                .help(tr("Remove"))
                        }
                    }
                    if !badKeys.isEmpty {
                        note(tr("Names use letters, digits and _, and can't start with a digit: \(badKeys.joined(separator: tr(", ")))"), color: theme.c.danger)
                    }
                    Button {
                        draft.env.append(EnvVar(key: "", value: ""))
                    } label: {
                        Label(tr("Add Variable"), systemImage: "plus")
                    }
                    .buttonStyle(.themed(.secondary, compact: true))
                }
                .padding(14)
            }
        }
        .card(fill: theme.c.surface, shadow: false)
    }

    private func loadGit() async {
        let folder = draft.folder.trimmingCharacters(in: .whitespaces)
        guard let conn, !folder.isEmpty else { git = nil; return }
        try? await Task.sleep(nanoseconds: 250_000_000)  // typing debounce
        checkingGit = true
        let info = await conn.gitInfo(folder)
        checkingGit = false
        guard !Task.isCancelled else { return }
        git = info
        if info?.isRepo == false { draft.worktree = false; draft.branch = nil }
    }
}
