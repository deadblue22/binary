import SwiftUI

/// Browses directories on the server (which may be a remote machine).
struct DirectoryBrowser: View {
    let conn: ServerConnection
    let initial: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var listing: DirListing?
    @State private var pathField = ""
    @State private var selection: String?
    @State private var error: String?
    @State private var showHidden = false
    @State private var newFolder = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { if let p = listing?.parent, !p.isEmpty { load(p) } } label: { Image(systemName: "chevron.up") }
                    .disabled((listing?.parent ?? "").isEmpty)
                    .help(tr("Up one level"))
                Button { load("~") } label: { Image(systemName: "house") }
                    .help(tr("Home"))
                TextField(tr("Path"), text: $pathField)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { load(pathField) }
                Toggle(tr("Hidden items"), isOn: $showHidden)
                    .toggleStyle(.checkbox)
                    .onChange(of: showHidden) { _, _ in if let p = listing?.path { load(p) } }
            }
            .padding(10)
            Divider()
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let listing {
                List(listing.entries, selection: $selection) { e in
                    Label {
                        Text(e.name)
                    } icon: {
                        Image(systemName: e.isGit == true ? "shippingbox" : "folder")
                            .foregroundStyle(e.isGit == true ? Color.orange : Color.accentColor)
                    }
                    .tag(e.path)
                    .slimScrollers()
                }
                .contextMenu(forSelectionType: String.self) { _ in
                    EmptyView()
                } primaryAction: { paths in
                    if let p = paths.first { load(p) }
                }
                .overlay {
                    if listing.entries.isEmpty {
                        Text(tr("No subfolders")).foregroundStyle(.tertiary)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button(tr("New Folder…")) {
                    newFolderName = ""
                    newFolder = true
                }
                .disabled(listing == nil)
                if listing?.isGit == true {
                    Label(tr("git repository"), systemImage: "shippingbox").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Text(tr("Double-click to open a folder")).font(.caption).foregroundStyle(.tertiary)
                Button(tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selection == nil ? tr("Choose This Folder") : tr("Choose")) {
                    if let p = selection ?? listing?.path {
                        onPick(p)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(listing == nil)
            }
            .padding(10)
        }
        .frame(width: 620, height: 480)
        .task { load(initial) }
        .alert(tr("New Folder"), isPresented: $newFolder) {
            TextField(tr("Name"), text: $newFolderName)
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Create")) { mkdir() }
        } message: {
            Text(tr("Creates it in \(listing?.path ?? "")"))
        }
    }

    private func load(_ path: String) {
        Task {
            do {
                let l = try await conn.listDirs(path, hidden: showHidden)
                listing = l
                pathField = l.path
                selection = nil
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
                load(base)
                selection = p
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
