import SwiftUI

/// Servers, appearance and the local cache.
struct SettingsSheet: View {
    @Environment(ServerStore.self) private var store
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var cacheBytes: Int64?
    @State private var confirmClear = false

    var body: some View {
        @Bindable var appearance = appearance
        NavigationStack {
            Form {
                Section {
                    ForEach(store.orderedConnections) { c in
                        NavigationLink {
                            ServerEditor(config: c.config) { store.update($0) }
                        } label: {
                            ServerLine(conn: c)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.servers[$0].id }
                        ids.forEach(store.remove)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                    NavigationLink {
                        ServerEditor(config: nil) { store.add($0) }
                    } label: {
                        Label(tr("Add Server"), systemImage: "plus")
                    }
                } header: {
                    Text(tr("Servers"))
                } footer: {
                    Text(tr("The token grants shell access to that machine. Reach servers over Tailscale (HTTPS), a VPN or your local network, never plain HTTP on the internet."))
                }

                Section(tr("Appearance")) {
                    Picker(tr("Language"), selection: $appearance.language) {
                        ForEach(AppLanguage.allCases) { l in Text(l.label).tag(l) }
                    }
                    Picker(tr("Style"), selection: $appearance.style) {
                        ForEach(ThemeStyle.allCases) { s in Text(s == .binary ? tr("Binary (default)") : "Primary").tag(s) }
                    }
                    Picker(tr("Mode"), selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases) { m in Text(m.label).tag(m) }
                    }
                    Picker(tr("Text Size"), selection: $appearance.fontSize) {
                        ForEach(FontSizeLevel.allCases) { f in Text(f.label).tag(f) }
                    }
                }

                Section {
                    HStack {
                        Text(tr("Local cache"))
                        Spacer()
                        Text(cacheBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .foregroundStyle(theme.c.textMuted)
                    }
                    Button(tr("Clear Cache"), role: .destructive) { confirmClear = true }
                        .disabled(cacheBytes == 0)
                } footer: {
                    Text(tr("Recently opened conversations, session lists and images, kept on this phone so sessions on slow links open at once."))
                }

                Section {
                    HStack {
                        Text(tr("Version"))
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                            .foregroundStyle(theme.c.textMuted)
                    }
                }
            }
            .navigationTitle(tr("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.servers.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
            .task { cacheBytes = await LocalCache.shared.size() }
            .confirmationDialog(tr("Clear the local cache?"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button(tr("Clear Cache"), role: .destructive) {
                    LocalCache.shared.clear()
                    Task { cacheBytes = await LocalCache.shared.size() }
                }
            } message: {
                Text(tr("Sessions load from their servers again the next time you open them."))
            }
        }
        // Rebuild when the language changes.
        .id(appearance.language)
    }
}

private struct ServerLine: View {
    let conn: ServerConnection
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(conn.status == .online ? theme.c.success : (conn.status == .connecting ? theme.c.warning : theme.c.danger))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(conn.displayName)
                    .foregroundStyle(theme.c.text)
                Text(statusLine)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textFaint)
                    .lineLimit(1)
            }
        }
    }

    private var statusLine: String {
        if case .offline(let m) = conn.status { return m }
        if let i = conn.info { return "\(i.hostname) · claude \(i.claudeVersion)" }
        return conn.config.url
    }
}

/// Add or edit a server: address and token, typed or pasted from what
/// `binaryd token` prints, with a connection test.
struct ServerEditor: View {
    let config: ServerConfig?
    /// Shown as its own sheet (a Cancel button), not pushed in Settings.
    var standalone = false
    let onSave: (ServerConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var name = ""
    @State private var url = "https://"
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false
    @State private var pasteNote: String?

    private var valid: Bool { URL(string: url.trimmingCharacters(in: .whitespaces))?.host != nil && !token.isEmpty }

    var body: some View {
        Form {
            Section {
                Button {
                    paste()
                } label: {
                    Label(tr("Paste from Clipboard"), systemImage: "doc.on.clipboard")
                }
                if let pasteNote {
                    Text(pasteNote)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.c.textMuted)
                }
            } footer: {
                Text(tr("Run `binaryd token` on the server, copy its output (Name, URL and Token), and paste it here. With Universal Clipboard, copy on the Mac and paste on the phone."))
            }
            Section {
                LabeledField(label: tr("Name")) {
                    TextField(tr("Name"), text: $name, prompt: Text(tr("e.g. devbox")))
                }
                LabeledField(label: tr("Address")) {
                    TextField(tr("Address"), text: $url, prompt: Text("https://devbox.tailnet.ts.net:7350"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledField(label: "Token") {
                    SecureField("Token", text: $token, prompt: Text("bin_…"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text(tr("binaryd listens on 127.0.0.1 by default, which the phone can't reach. Give it an address the phone can: `tailscale serve --bg --https 7350 http://127.0.0.1:7350` on the server, then use https://<machine>.<tailnet>.ts.net:7350."))
            }
            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Text(tr("Test Connection"))
                        if testing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(testing || !valid)
                if let result {
                    Text(result)
                        .font(theme.font(.caption))
                        .foregroundStyle(ok ? theme.c.success : theme.c.danger)
                }
            }
        }
        .navigationTitle(config == nil ? tr("Add Server") : (config?.name.isEmpty == false ? config!.name : tr("Server")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if standalone {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(config == nil ? tr("Add") : tr("Save")) {
                    var c = config ?? ServerConfig(name: "", url: "", token: "")
                    c.name = name.trimmingCharacters(in: .whitespaces)
                    c.url = url.trimmingCharacters(in: .whitespaces)
                    c.token = token.trimmingCharacters(in: .whitespaces)
                    onSave(c)
                    dismiss()
                }
                .disabled(!valid)
            }
        }
        .onAppear {
            if let config {
                name = config.name
                url = config.url
                token = config.token
            }
        }
    }

    private func paste() {
        let found = ServerPaste.parse(UIPasteboard.general.string ?? "")
        if let n = found.name, name.isEmpty || config == nil { name = n }
        if let u = found.url { url = u }
        if let t = found.token { token = t }
        if found.url == nil && found.token == nil {
            pasteNote = tr("The clipboard has no server address or token.")
        } else if let u = found.url, let host = URL(string: u)?.host, ["127.0.0.1", "localhost", "::1"].contains(host) {
            pasteNote = tr("That address only works on the server itself; change it to one the phone can reach.")
        } else {
            pasteNote = nil
        }
        result = nil
    }

    private func test() {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return }
        testing = true
        result = nil
        let api = APIClient(baseURL: u, token: token.trimmingCharacters(in: .whitespaces))
        Task {
            do {
                let info: ServerInfo = try await api.get("/info")
                ok = true
                result = "\(info.name) · \(info.os)/\(info.arch) · claude \(info.claudeVersion)"
                if name.isEmpty { name = info.name }
            } catch {
                ok = false
                result = error.localizedDescription
            }
            testing = false
        }
    }
}

/// A form row: a fixed-width label, then the field.
private struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder let field: () -> Field
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(theme.c.textMuted)
                .frame(width: 76, alignment: .leading)
            field()
        }
    }
}

/// Reads a server out of pasted text: `binaryd token`'s "Name: / URL: /
/// Token:" lines, or just an address and a token anywhere in it.
enum ServerPaste {
    static func parse(_ text: String) -> (name: String?, url: String?, token: String?) {
        var name: String?, url: String?, token: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = value(line, "Name:") { name = v }
            if let v = value(line, "URL:") { url = v }
            if let v = value(line, "Token:") { token = v }
        }
        if url == nil, let r = text.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression) {
            url = String(text[r])
        }
        if token == nil, let r = text.range(of: #"bin_[A-Za-z0-9_-]+"#, options: .regularExpression) {
            token = String(text[r])
        }
        return (name, url, token)
    }

    private static func value(_ line: String, _ key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let v = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}
