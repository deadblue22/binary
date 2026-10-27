import SwiftUI

#if os(macOS)
struct SessionDetailView: View {
    @Bindable var controller: SessionController
    @Environment(\.theme) private var theme
    @Environment(Navigation.self) private var nav
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var attachments: [PendingImage] = []
    @State private var dropTarget = false

    private var summary: SessionSummary? { controller.summary }

    var body: some View {
        VStack(spacing: 0) {
            if controller.loaded {
                TranscriptView(source: controller, jump: nav.jump?.ref == controller.ref ? nav.jump : nil,
                               onJumped: { if nav.jump?.ref == controller.ref { nav.jump = nil } })
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
                    .task {
                        guard DebugHooks.env["BINARY_LOAD_OLDER"] == "1" else { return }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        await controller.loadOlder()
                    }
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
                    .frame(maxWidth: theme.readingWidth)
                    .frame(maxWidth: .infinity)
                    .slimScrollers()
                }
                .frame(maxHeight: 420 * min(theme.scale, 1.3))
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
        .fillAvailable()
        .background(theme.c.background)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.c.focus, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(theme.c.focus.opacity(0.06))
                    .overlay(Label(tr("Drop images to attach"), systemImage: "photo.on.rectangle")
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.c.focus))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .imageDrop(isTargeted: $dropTarget) { new in
            let room = ImageProcessor.maxPerMessage - attachments.count
            attachments += new.prefix(max(room, 0))
        }
        .environment(\.imageSource, ImageSource(
            load: { [conn = controller.conn, id = controller.id] key in await conn.image(session: id, key: key) },
            data: { [conn = controller.conn, id = controller.id] key in await conn.imageData(session: id, key: key) }))
        .environment(\.subagentOpener, opener)
        .task(id: controller.id) {
            if let s = summary { await controller.conn.checkFolder(s) }
        }
        .task(id: summary?.subagentCount ?? 0) {
            if (summary?.subagentCount ?? 0) > 0 { await controller.conn.loadSubagents(controller.id) }
        }
        .navigationTitle(summary?.title ?? "Session")
        .navigationSubtitle(subtitle)
        .toolbarTitleMenu { sessionMenu }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !controller.connected && controller.loaded {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(theme.c.warning)
                        .help(tr("Lost the live connection to the server; reconnecting"))
                }
                InspectorToggle()
            }
        }
        .onChange(of: nav.renameRequest) { _, _ in
            newTitle = summary?.title ?? ""
            renaming = true
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
        Button(tr("Rename…")) {
            newTitle = summary?.title ?? ""
            renaming = true
        }
        Button(tr("Copy Session ID")) { copy(controller.id) }
        Button(tr("Copy Resume Command")) {
            if let s = summary { copy(s.resumeCommand) }
        }
        if let s = summary {
            Button(tr("Copy Working Directory")) { copy(s.cwd) }
        }
        if summary?.external?.working == true {
            Divider()
            Button(tr("Take Over and Interrupt")) { Task { await controller.takeover() } }
        }
        Divider()
        Button(tr("Stop Process")) { Task { await controller.stopProcess() } }
            .disabled(summary?.live != true)
    }

    /// Matches a Task/Agent tool call to a subagent of this session.
    private var opener: SubagentOpener? {
        .forSession(controller.conn, controller.id, nav: nav)
    }
}
#endif

/// Over a transcript shown from the local cache until the server answers.
struct SavedCopyHint: View {
    let offline: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if offline {
                Image(systemName: "wifi.slash")
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(offline ? tr("Offline · saved copy") : tr("Updating…"))
        }
        .font(theme.font(.small))
        .foregroundStyle(theme.c.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.c.surface))
        .overlay(Capsule().strokeBorder(theme.c.border))
        .shadow(color: theme.c.shadow, radius: 3, y: 1)
        .allowsHitTesting(false)
    }
}

/// Replaces the composer for view-only sessions (run over SSH, or their
/// folder is gone).
struct ViewOnlyBar: View {
    let session: SessionSummary
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .font(.system(size: theme.size(.body)))
                .foregroundStyle(theme.c.textMuted)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.sshHost.map { tr("View only · ran over SSH on \($0)") }
                     ?? tr("View only · folder no longer exists"))
                    .font(theme.font(.callout).weight(.semibold))
                    .foregroundStyle(theme.c.text)
                Text(session.sshHost.map { host in
                        tr("It runs on \(host) through Claude desktop's SSH environment, so Binary can show it but can't send to it. Continue it in Claude desktop, or add \(host)'s binaryd as a server.")
                     } ?? tr("Its folder \(Format.path(session.cwd, cwd: nil)) no longer exists (for example, a removed worktree), so it can't be resumed here."))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(fill: theme.c.surfaceAlt, shadow: false)
        .padding(.horizontal, theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: theme.readingWidth)
        .frame(maxWidth: .infinity)
        .background(theme.c.background)
    }
}

#if os(macOS)
/// Toolbar button that shows or hides the session info panel (⌥⌘I).
struct InspectorToggle: View {
    @Environment(AppearanceStore.self) private var appearance

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { appearance.showInspector.toggle() }
        } label: {
            Label(tr("Session Info"), systemImage: "sidebar.trailing")
        }
        .help(appearance.showInspector ? tr("Hide session info (⌥⌘I)") : tr("Show session info (⌥⌘I)"))
        .keyboardShortcut("i", modifiers: [.command, .option])
    }
}
#endif

struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.c.warning)
            Text(text)
                .font(theme.font(.callout))
                .foregroundStyle(theme.c.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 20))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.c.warning.opacity(0.12))
        .overlay(alignment: .top) { Rectangle().fill(theme.c.warning.opacity(0.3)).frame(height: 1) }
    }
}

struct LoadingView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(tr("Loading…"))
                .font(theme.font(.callout))
                .foregroundStyle(theme.c.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.c.background)
    }
}
