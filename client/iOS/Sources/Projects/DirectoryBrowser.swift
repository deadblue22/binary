import SwiftUI

/// Browses folders on the server (which may be a remote machine). Tap a
/// folder to go into it; "Choose" takes the folder shown.
struct DirectoryBrowser: View {
    let conn: ServerConnection
    let initial: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var listing: DirListing?
    @State private var error: String?
    @State private var showHidden = false
    @State private var newFolder = false
    @State private var newFolderName = ""
    @State private var editingPath = false
    @State private var pathText = ""

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error)
                        .font(theme.font(.callout))
                        .foregroundStyle(theme.c.danger)
                }
                if let listing {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: listing.isGit == true ? "shippingbox" : "folder")
                                .foregroundStyle(listing.isGit == true ? theme.c.warning : theme.c.focus)
                            Text(Format.path(listing.path, cwd: nil))
                                .font(theme.mono(theme.size(.caption)))
                                .foregroundStyle(theme.c.textMuted)
                                .lineLimit(2)
                                .truncationMode(.head)
                            if listing.isGit == true {
                                Spacer(minLength: 4)
                                Chip(text: "git", tint: theme.c.warning)
                            }
                        }
                        if let parent = listing.parent, !parent.isEmpty {
                            Button { load(parent) } label: {
                                Label(tr("Up one level"), systemImage: "arrow.turn.left.up")
                            }
                        }
                    }
                    Section {
                        if listing.entries.isEmpty {
                            Text(tr("No subfolders")).foregroundStyle(theme.c.textFaint)
                        }
                        ForEach(listing.entries) { e in
                            Button { load(e.path) } label: {
                                HStack {
                                    Label {
                                        Text(e.name).foregroundStyle(theme.c.text)
                                    } icon: {
                                        Image(systemName: e.isGit == true ? "shippingbox" : "folder")
                                            .foregroundStyle(e.isGit == true ? theme.c.warning : theme.c.focus)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: theme.size(.small), weight: .semibold))
                                        .foregroundStyle(theme.c.textFaint)
                                }
                            }
                        }
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(listing.map { ($0.path as NSString).lastPathComponent } ?? tr("Folders"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Choose")) {
                        if let p = listing?.path {
                            onPick(p)
                            dismiss()
                        }
                    }
                    .disabled(listing == nil)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { load("~") } label: { Label(tr("Home"), systemImage: "house") }
                    Spacer()
                    Menu {
                        Toggle(tr("Hidden items"), isOn: $showHidden)
                        Button {
                            pathText = listing?.path ?? ""
                            editingPath = true
                        } label: { Label(tr("Go to Path…"), systemImage: "arrow.right.circle") }
                        Button {
                            newFolderName = ""
                            newFolder = true
                        } label: { Label(tr("New Folder…"), systemImage: "folder.badge.plus") }
                        .disabled(listing == nil)
                    } label: {
                        Label(tr("More"), systemImage: "ellipsis.circle")
                    }
                }
            }
            .onChange(of: showHidden) { _, _ in if let p = listing?.path { load(p) } }
            .task { load(initial) }
            .alert(tr("New Folder"), isPresented: $newFolder) {
                TextField(tr("Name"), text: $newFolderName)
                Button(tr("Cancel"), role: .cancel) {}
                Button(tr("Create")) { mkdir() }
            } message: {
                Text(tr("Creates it in \(listing?.path ?? "")"))
            }
            .alert(tr("Go to Path"), isPresented: $editingPath) {
                TextField(tr("Path"), text: $pathText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(tr("Cancel"), role: .cancel) {}
                Button(tr("Open")) { load(pathText) }
            }
        }
    }

    private func load(_ path: String) {
        Task {
            do {
                let l = try await conn.listDirs(path, hidden: showHidden)
                listing = l
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func mkdir() {
        guard let base = listing?.path else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }
        Task {
            do {
                let p = try await conn.mkdir((base as NSString).appendingPathComponent(name))
                load(p)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
