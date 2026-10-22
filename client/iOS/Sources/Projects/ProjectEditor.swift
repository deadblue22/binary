import SwiftUI

/// Create or edit a project: name, folder with branch and worktree, the
/// settings new sessions start with, and environment variables.
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
    @State private var confirmDelete = false

    private var conn: ServerConnection? { store.connection(draft.server) }
    private var badKeys: [String] { draft.env.map(\.key).filter { !$0.isEmpty && !EnvVar.isValidName($0) } }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.folder.trimmingCharacters(in: .whitespaces).isEmpty && badKeys.isEmpty
    }
    private var isRepo: Bool { git?.isRepo == true }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Name")) {
                    TextField(tr("e.g. my-app"), text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if store.orderedConnections.count > 1 {
                    Picker(tr("Server"), selection: $draft.server) {
                        ForEach(store.orderedConnections) { c in Text(c.displayName).tag(c.id) }
                    }
                }
                Section {
                    HStack {
                        TextField("/path/to/project", text: $draft.folder)
                            .font(theme.mono(theme.size(.callout)))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if checkingGit { ProgressView() }
                        Button { browsing = true } label: { Image(systemName: "folder.badge.plus") }
                            .buttonStyle(.borderless)
                            .disabled(conn?.status != .online)
                            .accessibilityLabel(tr("Browse…"))
                    }
                    Picker(tr("Branch"), selection: Binding(get: { draft.branch ?? "" }, set: { draft.branch = $0.isEmpty ? nil : $0 })) {
                        Text(tr("Current") + (git?.current.map { " (\($0))" } ?? "")).tag("")
                        ForEach(git?.branches ?? [], id: \.self) { b in Text(b).tag(b) }
                    }
                    .disabled(!isRepo)
                    Toggle(tr("New Worktree for Each Session"), isOn: $draft.worktree)
                        .disabled(!isRepo)
                } header: {
                    Text(tr("Folder"))
                } footer: {
                    gitNote
                }
                Section {
                    let models = (conn?.info?.models ?? []).filter { $0.value != "default" }
                    Picker(tr("Model"), selection: $draft.model) {
                        Text(tr("Default")).tag("")
                        ForEach(models) { m in Text(m.displayName).tag(m.value) }
                        if !draft.model.isEmpty, !models.contains(where: { $0.value == draft.model }) {
                            Text(draft.model).tag(draft.model)
                        }
                    }
                    Picker("Effort", selection: $draft.effort) {
                        Text(tr("Default")).tag("")
                        ForEach(conn?.effortLevels(for: draft.model.isEmpty ? nil : draft.model) ?? [], id: \.self) { l in
                            Text(Format.effort(l)).tag(l)
                        }
                    }
                    Picker(tr("Permission Mode"), selection: $draft.permissionMode) {
                        Text(tr("Default")).tag("")
                        ForEach(conn?.info?.permissionModes ?? Format.modeKeys, id: \.self) { m in Text(Format.mode(m)).tag(m) }
                    }
                } header: {
                    Text(tr("New sessions"))
                } footer: {
                    Text(tr("Each new session here starts with these, and starting one with other settings updates them."))
                }
                Section {
                    ForEach($draft.env) { $v in
                        HStack(spacing: 6) {
                            TextField("NAME", text: $v.key)
                                .font(theme.mono(theme.size(.callout)))
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                            Text("=").foregroundStyle(theme.c.textFaint)
                            TextField(tr("value"), text: $v.value)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    .onDelete { draft.env.remove(atOffsets: $0) }
                    Button {
                        draft.env.append(EnvVar(key: "", value: ""))
                    } label: {
                        Label(tr("Add Variable"), systemImage: "plus")
                    }
                } header: {
                    Text(tr("Environment variables"))
                } footer: {
                    if !badKeys.isEmpty {
                        Text(tr("Names use letters, digits and _, and can't start with a digit: \(badKeys.joined(separator: tr(", ")))"))
                            .foregroundStyle(theme.c.danger)
                    }
                }
                if !isNew, onDelete != nil {
                    Section {
                        Button(tr("Delete Project"), role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? tr("New Project") : tr("Edit Project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Save")) {
                        var p = draft
                        p.name = p.name.trimmingCharacters(in: .whitespaces)
                        p.folder = p.folder.trimmingCharacters(in: .whitespaces)
                        p.env = p.env.filter { !$0.key.isEmpty }
                        onSave(p)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
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
    }

    @ViewBuilder
    private var gitNote: some View {
        if let git, !draft.folder.isEmpty {
            if !git.isRepo {
                Text(tr("Not a git repository: branch and worktree are off."))
            } else if draft.worktree {
                Text(tr("Each session gets .claude/worktrees/<name> on branch claude/<name>, cut from \(draft.branch ?? git.current ?? "HEAD")."))
            } else if let b = draft.branch, b != git.current {
                let dirty = git.dirty == true ? tr("; it has uncommitted changes, so that will fail") : ""
                Text(tr("Sessions switch the folder to \(b) first\(dirty)."))
                    .foregroundStyle(git.dirty == true ? theme.c.warning : theme.c.textMuted)
            }
        }
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
