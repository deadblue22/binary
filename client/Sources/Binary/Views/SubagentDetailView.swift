import SwiftUI

/// Read-only view of a subagent's conversation, in the same transcript view
/// as the main session.
struct SubagentDetailView: View {
    let controller: SubagentController
    @Environment(Navigation.self) private var nav
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var appearance = appearance
        VStack(spacing: 0) {
            if controller.loaded {
                TranscriptView(source: controller)
                    .environment(\.fileLinkHandler, FileLinks.handler(server: controller.conn.id, session: controller.sessionID, nav: nav))
                    .environment(\.openURL, OpenURLAction { url in
                        FileLinks.handler(server: controller.conn.id, session: controller.sessionID, nav: nav).open(url)
                        return .handled
                    })
            } else {
                LoadingView()
            }
            if let notice = controller.notice {
                NoticeBar(text: notice) { controller.notice = nil }
            }
            footer
        }
        .fillAvailable()
        .background(theme.c.background)
        .environment(\.imageSource, ImageSource(
            load: { [conn = controller.conn, id = controller.sessionID] key in await conn.image(session: id, key: key) },
            data: { [conn = controller.conn, id = controller.sessionID] key in await conn.imageData(session: id, key: key) }))
        .navigationTitle(controller.title)
        .navigationSubtitle("Subagent · " + (controller.parent?.title ?? ""))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await controller.refresh() }
                } label: {
                    Label(tr("Refresh"), systemImage: "arrow.clockwise")
                }
                .help(tr("Reload the subagent's conversation (⌘R)"))
                .disabled(controller.refreshing)
                .keyboardShortcut("r")
                InspectorToggle()
            }
        }
        .sessionInspector(isPresented: $appearance.showInspector, width: InspectorLayout.width(theme)) {
            SessionInspector(conn: controller.conn, sessionID: controller.sessionID, currentAgent: controller.agentID)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
            Text(tr("Read-only: subagents are driven by their parent session.")
                 + (controller.transcriptBusy ? tr(" Parent is running, refreshing every 3 s.") : ""))
                .lineLimit(2)
            Spacer(minLength: 12)
            if let p = controller.parent {
                Button {
                    nav.selection = SessionRef(server: controller.conn.id, session: p.id)
                } label: {
                    Label(tr("Back to Parent Session"), systemImage: "arrow.turn.left.up")
                }
                .buttonStyle(.themed(.secondary, compact: true))
            }
        }
        .font(theme.font(.caption))
        .foregroundStyle(theme.c.textMuted)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: theme.readingWidth)
        .frame(maxWidth: .infinity)
        .background(theme.c.surfaceAlt.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(theme.c.border).frame(height: 1) }
    }
}
