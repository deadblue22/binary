import SwiftUI

/// One session: the live transcript, approvals waiting above the message box,
/// and the message box itself. The title opens the session menu; the info
/// button opens what the Mac shows in its right-hand panel.
struct PhoneSessionView: View {
    @Bindable var controller: SessionController
    @Environment(\.theme) private var theme
    @Environment(Navigation.self) private var nav
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var attachments: [PendingImage] = []

    private var summary: SessionSummary? { controller.summary }

    var body: some View {
        @Bindable var nav = nav
        VStack(spacing: 0) {
            if controller.loaded {
                TranscriptView(source: controller)
                    .environment(\.fileLinkHandler, FileLinks.handler(server: controller.conn.id, session: controller.id, nav: nav))
                    .environment(\.openURL, OpenURLAction { url in
                        FileLinks.handler(server: controller.conn.id, session: controller.id, nav: nav).open(url)
                        return .handled
                    })
                    .overlay(alignment: .top) {
                        if controller.refreshing {
                            SavedCopyHint(offline: controller.conn.status != .online)
                                .padding(.top, 8)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: controller.refreshing)
            } else {
                LoadingView()
            }
            if let notice = controller.notice {
                NoticeBar(text: notice) { controller.notice = nil }
            }
            if !controller.permissions.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(controller.permissions) { req in
                            PermissionCard(req: req, controller: controller)
                        }
                    }
                    .padding(.horizontal, theme.gutter)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 380 * min(theme.scale, 1.3))
                .fixedSize(horizontal: false, vertical: true)
            }
            if let s = summary, controller.conn.isViewOnly(s) {
                ViewOnlyBar(session: s)
            } else {
                ComposerView(controller: controller, images: $attachments)
                    .onAppear { attachments = ComposerDrafts.shared.images(for: controller.ref) }
                    .onChange(of: attachments) { _, list in ComposerDrafts.shared.setImages(list, for: controller.ref) }
            }
        }
        .background(theme.c.background)
        .environment(\.imageSource, ImageSource(
            load: { [conn = controller.conn, id = controller.id] key in await conn.image(session: id, key: key) },
            data: { [conn = controller.conn, id = controller.id] key in await conn.imageData(session: id, key: key) }))
        .environment(\.subagentOpener, .forSession(controller.conn, controller.id, nav: nav))
        .task(id: controller.id) {
            if let s = summary { await controller.conn.checkFolder(s) }
        }
        .task(id: summary?.subagentCount ?? 0) {
            if (summary?.subagentCount ?? 0) > 0 { await controller.conn.loadSubagents(controller.id) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.c.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu { sessionMenu } label: {
                    NavTitle(title: summary?.title ?? tr("Session"), subtitle: subtitle)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !controller.connected && controller.loaded {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(theme.c.warning)
                        .accessibilityLabel(tr("Lost the live connection to the server; reconnecting"))
                }
                Button { nav.showingInfo = true } label: {
                    Label(tr("Session Info"), systemImage: "info.circle")
                }
            }
        }
        .sheet(isPresented: $nav.showingInfo) {
            SessionInfoSheet(conn: controller.conn, sessionID: controller.id, connected: controller.connected)
        }
        .alert(tr("Rename Session"), isPresented: $renaming) {
            TextField(tr("Title"), text: $newTitle)
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Save")) { Task { await controller.update(SettingsUpdate(title: newTitle)) } }
        }
    }

    private var subtitle: String {
        guard let s = summary else { return controller.conn.displayName }
        return [s.project.isEmpty ? Format.path(s.cwd, cwd: nil) : s.project, controller.conn.displayName].joined(separator: " · ")
    }

    @ViewBuilder
    private var sessionMenu: some View {
        Button {
            newTitle = summary?.title ?? ""
            renaming = true
        } label: { Label(tr("Rename…"), systemImage: "pencil") }
        Button { nav.newChildSession(of: controller.ref) } label: {
            Label(tr("New Child Session"), systemImage: "plus.bubble")
        }
        Divider()
        Button { copy(controller.id) } label: { Label(tr("Copy Session ID"), systemImage: "number") }
        Button {
            if let s = summary { copy(s.resumeCommand) }
        } label: { Label(tr("Copy Resume Command"), systemImage: "terminal") }
        if let s = summary {
            Button { copy(s.cwd) } label: { Label(tr("Copy Working Directory"), systemImage: "folder") }
        }
        Divider()
        Button(role: .destructive) { Task { await controller.stopProcess() } } label: {
            Label(tr("Stop Process"), systemImage: "stop.circle")
        }
        .disabled(summary?.live != true)
    }
}

/// Title and a smaller line under it, for the navigation bar.
struct NavTitle: View {
    let title: String
    let subtitle: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Text(title)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.c.heading)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: theme.size(.small), weight: .semibold))
                    .foregroundStyle(theme.c.textFaint)
            }
            Text(subtitle)
                .font(theme.font(.small))
                .foregroundStyle(theme.c.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: 260)
    }
}

/// The Mac's info panel as a sheet: where the session runs, its process and
/// background tasks, group / pin / archive, usage, child sessions and subagents.
struct SessionInfoSheet: View {
    let conn: ServerConnection
    let sessionID: String
    var connected = true
    var currentAgent: String? = nil
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            SessionInspector(conn: conn, sessionID: sessionID, connected: connected, currentAgent: currentAgent,
                             onRename: currentAgent == nil ? {
                                 newTitle = conn.sessions[sessionID]?.title ?? ""
                                 renaming = true
                             } : nil)
                .navigationTitle(conn.sessions[sessionID]?.title ?? tr("Session Info"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(tr("Done")) { dismiss() }
                    }
                }
                .alert(tr("Rename Session"), isPresented: $renaming) {
                    TextField(tr("Title"), text: $newTitle)
                    Button(tr("Cancel"), role: .cancel) {}
                    Button(tr("Save")) {
                        let title = newTitle
                        Task { try? await conn.update(sessionID, SettingsUpdate(title: title)) }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(theme.c.background)
    }
}
