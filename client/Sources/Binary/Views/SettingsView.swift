import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppearanceStore.self) private var appearance

    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label(tr("Appearance"), systemImage: "paintpalette") }
            ServersSettings()
                .tabItem { Label(tr("Servers"), systemImage: "server.rack") }
        }
        .frame(width: 700, height: 600)
        // Rebuild every tab when the language changes.
        .id(appearance.language)
    }
}

struct AppearanceSettings: View {
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var appearance = appearance
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(tr("Language")) {
                    Picker(tr("Language"), selection: $appearance.language) {
                        ForEach(AppLanguage.allCases) { l in Text(l.label).tag(l) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                section(tr("Style")) {
                    // Equal-height cards, top-aligned.
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(ThemeStyle.allCases) { style in
                            StyleCard(style: style, selected: appearance.style == style) {
                                appearance.style = style
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                section(tr("Mode")) {
                    Picker(tr("Mode"), selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases) { m in Text(m.label).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                section(tr("Text Size")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(tr("Text Size"), selection: $appearance.fontSize) {
                            ForEach(FontSizeLevel.allCases) { f in Text(f.label).tag(f) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Text(tr("Also in the View menu: ⌘+ / ⌘- / ⌘0. Body text is \(Int(theme.base.rounded())) pt."))
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.c.textMuted)
                        FontPreview()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("The Primary style's colors and type settings follow Primary for Obsidian (Cecilia May). Only color values and style parameters are used, none of its CSS."))
                    Text(fontNote)
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.c.textFaint)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .slimScrollers()
        }
        .background(theme.c.background)
    }

    private var fontNote: String {
        let inter = Fonts.inter ? tr("Inter is installed") : tr("Inter isn't installed, so text uses the system font")
        let mono = Fonts.cascadia != nil ? tr("Cascadia Code is installed") : tr("Cascadia Code isn't installed, so code uses SF Mono")
        return tr("The Primary style prefers Inter and Cascadia Code: \(inter); \(mono).")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(theme.font(.headline))
                .foregroundStyle(theme.c.heading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A theme choice shown as two tiny windows, light and dark.
private struct StyleCard: View {
    let style: ThemeStyle
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MiniWindow(p: style == .primary ? .primary : .binary, dark: false)
                    MiniWindow(p: style == .primary ? .primary : .binary, dark: true)
                }
                HStack {
                    Text(style == .binary ? tr("Binary (default)") : "Primary")
                        .font(theme.font(.callout).weight(.semibold))
                        .foregroundStyle(theme.c.text)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.c.focus)
                    }
                }
                Text(style == .binary ? tr("Cool slate and indigo, rounded cards and bubbles") : tr("Warm parchment and tactile keys (from the Obsidian theme)"))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? theme.c.hover : theme.c.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? theme.c.focus : theme.c.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct MiniWindow: View {
    let p: Palette
    let dark: Bool

    private func c(_ color: Color) -> Color { color.resolved(dark: dark) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == 1 ? c(p.selection) : c(p.textFaint).opacity(0.35))
                        .frame(height: 7)
                }
                Spacer()
            }
            .padding(5)
            .frame(width: 40)
            .background(c(p.sidebar))
            VStack(alignment: .trailing, spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(c(p.userBubble)).frame(width: 52, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(c(p.userBubbleBorder)))
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(c(p.text).opacity(0.7)).frame(height: 3)
                    RoundedRectangle(cornerRadius: 1).fill(c(p.text).opacity(0.7)).frame(width: 60, height: 3)
                }
                RoundedRectangle(cornerRadius: 3).fill(c(p.surface)).frame(height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(c(p.border)))
                Spacer()
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(c(p.input)).frame(height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(c(p.border)))
                    Circle().fill(c(p.accent)).frame(width: 10, height: 10)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(c(p.background))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(c(p.border)))
    }
}

private struct FontPreview: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UserMessageView(text: tr("Why does this function time out?"))
            MarkdownView(text: tr("The problem is that `fetchAll()` fetches pages **one after another**. Run them concurrently:\n\n```swift\nlet pages = try await withThrowingTaskGroup(of: Page.self) { … }\n```"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: theme.c.background)
    }
}

extension Color {
    /// This color as it looks in light or dark mode.
    func resolved(dark: Bool) -> Color {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = NSColor.gray
        appearance.performAsCurrentDrawingAppearance {
            out = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        }
        return Color(nsColor: out)
    }
}

struct ServersSettings: View {
    @Environment(ServerStore.self) private var store
    @State private var selection: UUID?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            servers
            Divider()
            CacheRow()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var servers: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.orderedConnections) { c in
                        HStack {
                            Circle()
                                .fill(c.status == .online ? Color.green : (c.status == .connecting ? .yellow : .red))
                                .frame(width: 7, height: 7)
                            Text(c.displayName)
                        }
                        .tag(c.id)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { adding = true; selection = nil } label: { Image(systemName: "plus") }
                        .frame(width: 26, height: 22)
                    Button {
                        if let id = selection { store.remove(id); selection = nil }
                    } label: { Image(systemName: "minus") }
                        .frame(width: 26, height: 22)
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 200)
            Divider()
            Group {
                if adding {
                    ServerEditor(config: nil) { cfg in
                        store.add(cfg)
                        adding = false
                        selection = cfg.id
                    }
                } else if let id = selection, let c = store.connection(id) {
                    ServerEditor(config: c.config) { cfg in store.update(cfg) }
                        .id(id)
                } else {
                    VStack(spacing: 10) {
                        Text(tr("Select or add a server")).foregroundStyle(.secondary)
                        if ServerStore.localServerConfig() != nil {
                            Button(tr("Import This Mac's binaryd Config")) {
                                if let l = ServerStore.localServerConfig() { store.add(l) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Size of the local cache, and a way to empty it.
private struct CacheRow: View {
    @State private var bytes: Int64?
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Local cache") + (bytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                Text(tr("Recently opened conversations, session lists and images, kept on this Mac (only your user can read them) so sessions on slow links open at once."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(tr("Clear Cache")) { confirming = true }
                .disabled(bytes == 0)
        }
        .task { bytes = await LocalCache.shared.size() }
        .confirmationDialog(tr("Clear the local cache?"), isPresented: $confirming) {
            Button(tr("Clear Cache"), role: .destructive) {
                LocalCache.shared.clear()
                Task { bytes = await LocalCache.shared.size() }
            }
        } message: {
            Text(tr("Sessions load from their servers again the next time you open them."))
        }
    }
}

struct ServerEditor: View {
    let config: ServerConfig?
    let onSave: (ServerConfig) -> Void

    @State private var name = ""
    @State private var url = "http://"
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        Form {
            TextField(tr("Name"), text: $name, prompt: Text(tr("e.g. devbox")))
            TextField(tr("Address"), text: $url, prompt: Text("http://127.0.0.1:7350"))
            SecureField("Token", text: $token, prompt: Text(tr("bin_… from `binaryd token`")))
            Section {
                HStack {
                    Button(tr("Test Connection")) { test() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(ok ? .green : .red)
                            .lineLimit(3)
                    }
                    Spacer()
                    Button(config == nil ? tr("Add") : tr("Save")) {
                        var c = config ?? ServerConfig(name: "", url: "", token: "")
                        c.name = name.trimmingCharacters(in: .whitespaces)
                        c.url = url.trimmingCharacters(in: .whitespaces)
                        c.token = token.trimmingCharacters(in: .whitespaces)
                        onSave(c)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(URL(string: url)?.host == nil || token.isEmpty)
                }
            } footer: {
                Text(tr("Reach remote servers through an SSH tunnel (ssh -L 7350:127.0.0.1:7350 host), HTTPS or a private network. The token grants shell access to that machine."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let config {
                name = config.name
                url = config.url
                token = config.token
            }
        }
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
