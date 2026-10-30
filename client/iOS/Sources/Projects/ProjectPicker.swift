import SwiftUI

/// The project list for a new session (the Mac shows it as a popover):
/// starred projects, each server's projects and recent folders, a folder
/// browser and "New Project…". Swipe a row to star it or edit its settings.
struct ProjectPicker: View {
    let current: StartTarget?
    let onPick: (StartTarget) -> Void
    let onNew: (UUID?) -> Void
    let onEdit: (Project) -> Void
    /// The options button on a plain folder: save it as a project with its settings.
    var onEditFolder: ((UUID, String) -> Void)? = nil
    var onBrowse: ((UUID) -> Void)? = nil
    @Environment(ServerStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recent: [UUID: [String]] = [:]

    private var q: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ name: String, _ folder: String) -> Bool {
        q.isEmpty || name.lowercased().contains(q) || folder.lowercased().contains(q)
    }

    var body: some View {
        NavigationStack {
            List {
                let favs = projects.favorites.filter { matches($0.name, $0.folder) }
                if !favs.isEmpty {
                    Section(tr("Starred")) {
                        ForEach(favs) { p in projectRow(p) }
                    }
                }
                ForEach(store.orderedConnections) { conn in
                    let own = projects.projects(on: conn.id).filter { !$0.starred && matches($0.name, $0.folder) }
                    let known = Set(projects.projects(on: conn.id).map(\.folder))
                    let dirs = (recent[conn.id] ?? []).filter { !known.contains($0) && matches(Project.defaultName(for: $0), $0) }
                    if !own.isEmpty || !dirs.isEmpty {
                        Section {
                            ForEach(own) { p in projectRow(p) }
                            ForEach(dirs, id: \.self) { d in folderRow(conn.id, d) }
                        } header: {
                            Label(conn.displayName, systemImage: "server.rack")
                        }
                    }
                }
                if projects.projects.isEmpty && recent.values.allSatisfy(\.isEmpty) {
                    Text(tr("No projects yet. Add one below, or pick a folder."))
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.c.textFaint)
                }
                Section {
                    if let onBrowse, let server = current?.server ?? store.orderedConnections.first?.id {
                        Button { after { onBrowse(server) } } label: {
                            Label(tr("Open Folder…"), systemImage: "folder.badge.plus")
                        }
                    }
                    Button { after { onNew(current?.server) } } label: {
                        Label(tr("New Project…"), systemImage: "plus")
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: tr("Search projects and folders…"))
            .navigationTitle(tr("Project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
            }
            .task {
                for conn in store.orderedConnections where conn.status == .online {
                    recent[conn.id] = (try? await conn.recentDirs()) ?? []
                }
            }
        }
    }

    /// Runs `action` once this list is gone: the editor and the folder
    /// browser are sheets too, and iOS shows one at a time.
    private func after(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
    }

    private func projectRow(_ p: Project) -> some View {
        Button {
            onPick(StartTarget(server: p.server, folder: p.folder, project: p.id))
        } label: {
            PickerLine(icon: p.worktree ? "square.stack.3d.up" : "folder", title: p.name,
                       subtitle: [Format.path(p.folder, cwd: nil), p.branch, p.worktree ? "worktree" : nil].compactMap { $0 }.joined(separator: " · "),
                       checked: current?.project == p.id, starred: p.starred)
        }
        .swipeActions(edge: .leading) {
            Button { projects.setStarred(p.id, !p.starred) } label: {
                Label(p.starred ? tr("Unstar") : tr("Star"), systemImage: p.starred ? "star.slash" : "star")
            }
            .tint(theme.c.warning)
        }
        .swipeActions(edge: .trailing) {
            Button { after { onEdit(p) } } label: {
                Label(tr("Edit"), systemImage: "slider.horizontal.3")
            }
            .tint(theme.c.focus)
        }
    }

    private func folderRow(_ server: UUID, _ folder: String) -> some View {
        Button {
            onPick(StartTarget(server: server, folder: folder, project: nil))
        } label: {
            PickerLine(icon: "clock", title: Project.defaultName(for: folder), subtitle: Format.path(folder, cwd: nil),
                       checked: current?.project == nil && current?.folder == folder && current?.server == server, starred: false)
        }
        .swipeActions(edge: .leading) {
            Button {
                // Starring a recent folder saves it as a project.
                var p = Project(name: Project.defaultName(for: folder), server: server, folder: folder)
                p.starred = true
                projects.save(p)
            } label: {
                Label(tr("Star"), systemImage: "star")
            }
            .tint(theme.c.warning)
        }
        .swipeActions(edge: .trailing) {
            if let onEditFolder {
                Button { after { onEditFolder(server, folder) } } label: {
                    Label(tr("Save as Project…"), systemImage: "slider.horizontal.3")
                }
                .tint(theme.c.focus)
            }
        }
    }
}

private struct PickerLine: View {
    let icon: String
    let title: String
    var subtitle: String
    var checked: Bool
    var starred: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(theme.c.textMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.c.text)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(theme.font(.small))
                        .foregroundStyle(theme.c.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if starred {
                Image(systemName: "star.fill").foregroundStyle(theme.c.warning)
            }
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: theme.size(.callout), weight: .semibold))
                    .foregroundStyle(theme.c.focus)
            }
        }
    }
}
