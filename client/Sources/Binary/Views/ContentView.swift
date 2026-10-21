import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var controller: SessionController?
    @State private var agent: SubagentController?
    @AppStorage("sidebarWidth") private var sidebarWidth = 320.0
    @AppStorage("showSidebar") private var showSidebar = true

    var body: some View {
        @Bindable var nav = nav
        // Plain columns: the split view's sidebar floats in an outlined, rounded
        // panel on recent macOS, which costs room and looks boxed in.
        HStack(spacing: 0) {
            if showSidebar {
                NavigationStack { SidebarView() }
                    .frame(width: sidebarWidth)
                    .background(theme.c.sidebar)
                ColumnDivider(width: $sidebarWidth, range: 240...520, side: .leading)
            }
            NavigationStack { detail }
                .frame(minWidth: 420)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(.easeOut(duration: 0.15)) { showSidebar.toggle() } } label: {
                    Label(tr("Toggle Sidebar"), systemImage: "sidebar.left")
                }
                .keyboardShortcut("b")
                .help(tr("Show or hide the sidebar (⌘B)"))
            }
        }
        .background(theme.c.background)
        // ⌘F also searches sessions, as before ⌘K became the menu shortcut.
        .background(Button("") { nav.searchRequest += 1 }.keyboardShortcut("f").opacity(0).frame(width: 0, height: 0))
        .toolbarBackground(theme.c.background, for: .windowToolbar)
        .sheet(item: $nav.filePreview) { FilePreviewView(request: $0) }
        .onChange(of: nav.selection) { _, ref in
            if ref != nil { nav.draft = nil }
            select(ref)
        }
        .onChange(of: theme.lang) { _, _ in reconnectForLanguage() }
        .task {
            guard DebugHooks.openSettings else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            openSettings()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let draft = nav.draft {
            NewSessionView(draft: draft)
                .id(draft.serial)
        } else if let agent {
            SubagentDetailView(controller: agent)
                .id(agent.ref)
        } else if let controller {
            SessionDetailView(controller: controller)
                .id(controller.ref)
        } else if store.servers.isEmpty {
            WelcomeView()
        } else {
            EmptyDetail()
        }
    }

    /// The server words activity, errors and notices in the language a stream
    /// was opened with, so reopen every stream after a switch.
    private func reconnectForLanguage() {
        for c in store.orderedConnections { c.reconnect() }
        let ref = nav.selection
        controller?.stop()
        controller = nil
        agent?.stop()
        agent = nil
        select(ref)
    }

    private func select(_ ref: SessionRef?) {
        if let ref, ref.agent != nil {
            if agent?.ref == ref { return }
            controller?.stop()
            controller = nil
            agent?.stop()
            guard let conn = store.connection(ref.server), let id = ref.agent else {
                agent = nil
                return
            }
            let a = SubagentController(conn: conn, sessionID: ref.session, agentID: id)
            a.start()
            agent = a
            return
        }
        agent?.stop()
        agent = nil
        if controller?.ref == ref { return }
        controller?.stop()
        guard let ref, let conn = store.connection(ref.server) else {
            controller = nil
            return
        }
        DebugHooks.openStarted = Date()
        let c = SessionController(conn: conn, id: ref.session)
        c.start()
        controller = c
    }
}

struct EmptyDetail: View {
    @Environment(Navigation.self) private var nav
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            IconTile(icon: "rectangle.stack", tint: theme.c.focus, size: 54)
            Text(tr("Select a Session"))
                .font(theme.font(.title))
                .foregroundStyle(theme.c.heading)
            Text(tr("Pick a session on the left to follow it live, or press ⌘N to start a new one."))
                .font(theme.font(.callout))
                .foregroundStyle(theme.c.textMuted)
            Button(tr("New Session")) { nav.newSession() }
                .buttonStyle(.themed(.primary))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.c.background)
    }
}

struct WelcomeView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Welcome to Binary"))
                .font(theme.font(.h1))
                .foregroundStyle(theme.c.heading)
            Text(tr("Binary manages Claude Code sessions on this Mac or on remote servers through binaryd."))
                .font(theme.font(.body))
                .foregroundStyle(theme.c.textMuted)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("1. Run the server on the machine you want to manage:")).font(theme.font(.body).weight(.semibold))
                MonoBox(text: tr("binaryd serve\nbinaryd token   # shows the address and token"), maxHeight: 80)
                Text(tr("2. A server on this Mac is found automatically; add remote servers in Settings.")).font(theme.font(.body).weight(.semibold))
            }
            .foregroundStyle(theme.c.text)
            HStack {
                Button(tr("Detect Local Server")) {
                    if let local = ServerStore.localServerConfig() { store.add(local) }
                }
                .buttonStyle(.themed(.primary))
                SettingsLink { Text(tr("Open Settings…")) }
                    .buttonStyle(.themed(.secondary))
            }
        }
        .padding(40)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.c.background)
    }
}
