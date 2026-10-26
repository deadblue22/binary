import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Suggestions for a message that starts with "/": the slash commands and
/// skills Claude Code offers there, filtered as the name is typed.
@MainActor @Observable
final class SlashSuggestions {
    private(set) var commands: [SlashCommand] = []
    private(set) var loading = false
    var selected = 0
    /// The name Esc closed the menu for; typing on opens it again.
    var dismissed: String?
    private var key: String?
    private var loadedAt = Date.distantPast

    /// The name being typed: what follows a leading "/", up to a space.
    static func query(_ text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let q = text.dropFirst()
        return q.contains(where: \.isWhitespace) ? nil : String(q)
    }

    /// The exact name first, then names that start with it, aliases that do,
    /// and names that contain it; each in the server's order.
    func matches(_ query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return commands }
        var tiers: [[SlashCommand]] = [[], [], [], []]
        for c in commands {
            let name = c.name.lowercased()
            if name == q { tiers[0].append(c) }
            else if name.hasPrefix(q) { tiers[1].append(c) }
            else if (c.aliases ?? []).contains(where: { $0.lowercased().hasPrefix(q) }) { tiers[2].append(c) }
            else if name.contains(q) { tiers[3].append(c) }
        }
        return tiers.flatMap { $0 }
    }

    /// Reads the list again once it is half a minute old, or for another session or folder.
    func load(conn: ServerConnection, session: String?, cwd: String?) async {
        let k = "\(conn.id) \(session ?? "") \(cwd ?? "")"
        guard k != key || Date().timeIntervalSince(loadedAt) > 30 else { return }
        if k != key { commands = [] }
        key = k
        loading = true
        let list = await conn.slashCommands(session: session, cwd: cwd)
        guard k == key else { return }
        loading = false
        if let list {
            commands = list
            loadedAt = Date()
        }
    }
}

extension View {
    /// Offers slash commands above a message box while its text starts with
    /// "/". Picking one fills in its name; on a Mac ↑↓ choose, ⇥ fills in, ↩
    /// runs a command that takes no arguments (`run` sends the box), ⎋ closes.
    func slashCommands(text: Binding<String>, focused: Bool, conn: ServerConnection?,
                       session: String? = nil, cwd: String? = nil, run: @escaping () -> Void) -> some View {
        modifier(SlashMenuModifier(text: text, focused: focused, conn: conn, session: session, cwd: cwd, run: run))
    }
}

private struct SlashMenuModifier: ViewModifier {
    @Binding var text: String
    let focused: Bool
    let conn: ServerConnection?
    let session: String?
    let cwd: String?
    let run: () -> Void
    @State private var s = SlashSuggestions()
    #if os(macOS)
    @State private var keys = MenuKeys()
    #endif

    private var query: String? { SlashSuggestions.query(text) }
    private var open: Bool { focused && query != nil && s.dismissed != query }
    private var shown: [SlashCommand] { open ? s.matches(query ?? "") : [] }
    private var selected: Int { min(s.selected, max(shown.count - 1, 0)) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                // A zero-height anchor at the box's top edge; the menu grows up from it.
                Color.clear
                    .frame(height: 0)
                    .overlay(alignment: .bottom) {
                        if open && (!shown.isEmpty || s.loading) {
                            SlashMenu(commands: shown, selected: selected, loading: s.loading, pick: accept)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 6)
                                .transition(.opacity)
                        }
                    }
            }
            .onChange(of: query) { _, _ in
                s.selected = 0
                s.dismissed = nil
            }
            .task(id: open) {
                guard open, let conn else { return }
                await s.load(conn: conn, session: session, cwd: cwd)
            }
            #if os(macOS)
            .onAppear { keys.install() }
            .onDisappear { keys.remove() }
            .onChange(of: open, initial: true) { _, o in keys.handle = o ? { key($0) } : nil }
            #endif
    }

    /// A command that takes arguments gets its name and a space; one that
    /// doesn't is sent as it is.
    private func accept(_ c: SlashCommand) {
        if (c.argumentHint ?? "").isEmpty {
            text = "/" + c.name
            DispatchQueue.main.async(execute: run)
        } else {
            complete(c)
        }
    }

    private func complete(_ c: SlashCommand) {
        text = "/\(c.name) "
    }

    #if os(macOS)
    /// Whether the key was the menu's.
    private func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if e.keyCode == 53 { // Esc
            s.dismissed = query
            return true
        }
        guard mods.isEmpty, !shown.isEmpty else { return false }
        switch e.keyCode {
        case 125: s.selected = (selected + 1) % shown.count       // ↓
        case 126: s.selected = (selected - 1 + shown.count) % shown.count // ↑
        case 48: complete(shown[selected])                      // Tab
        case 36, 76: accept(shown[selected])                    // Return, keypad Enter
        default: return false
        }
        return true
    }
    #endif
}

#if os(macOS)
/// Arrow keys, Tab, Return and Esc for the menu, ahead of the text field;
/// left alone while an input method is composing.
@MainActor
private final class MenuKeys {
    var handle: ((NSEvent) -> Bool)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let handle = self?.handle,
                  let editor = event.window?.firstResponder as? NSTextView,
                  !editor.hasMarkedText(),
                  handle(event) else { return event }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif

private struct SlashMenu: View {
    let commands: [SlashCommand]
    let selected: Int
    let loading: Bool
    let pick: (SlashCommand) -> Void
    @Environment(\.theme) private var theme

    #if os(macOS)
    private static let rows = 8
    #else
    private static let rows = 5
    #endif

    var body: some View {
        // The rows around the selection; typing narrows the rest.
        let start = selected < Self.rows ? 0 : selected - Self.rows + 1
        let window = Array(commands.enumerated()).dropFirst(start).prefix(Self.rows)
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius + 2, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty && loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Loading commands…"))
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.c.textFaint)
                .padding(10)
            }
            ForEach(window, id: \.element.id) { i, c in
                SlashRow(command: c, selected: i == selected)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(c) }
            }
            if commands.count > Self.rows {
                Text(footer)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(theme.c.surface))
        .overlay(shape.strokeBorder(theme.c.border))
        .shadow(color: theme.c.shadow, radius: 8, y: 2)
    }

    private var footer: String {
        #if os(macOS)
        tr("\(selected + 1) of \(commands.count) · ↑↓ to choose, ⇥ to fill in, ↩ to run")
        #else
        tr("\(commands.count) commands · keep typing to narrow them down")
        #endif
    }
}

private struct SlashRow: View {
    let command: SlashCommand
    let selected: Bool
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: command.builtin == true ? "terminal" : "wand.and.stars")
                .font(.system(size: theme.size(.caption)))
                .foregroundStyle(selected ? theme.c.selectionText : theme.c.textFaint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("/" + command.name)
                        .font(theme.font(.body).weight(.medium))
                        .foregroundStyle(selected ? theme.c.selectionText : theme.c.text)
                    if let hint = command.argumentHint, !hint.isEmpty {
                        Text(hint)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.c.textFaint)
                    }
                    if let aliases = command.aliases, !aliases.isEmpty {
                        Text(aliases.map { "/" + $0 }.joined(separator: " "))
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.c.textFaint)
                    }
                }
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(theme.font(.caption))
                        .foregroundStyle(selected ? theme.c.selectionText.opacity(0.8) : theme.c.textMuted)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
            .fill(selected ? theme.c.selection : hover ? theme.c.hover : .clear))
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
