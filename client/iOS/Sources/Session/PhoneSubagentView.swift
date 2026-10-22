import SwiftUI

/// Read-only view of a subagent's conversation, pushed over its parent session.
struct PhoneSubagentView: View {
    let controller: SubagentController
    @Environment(Navigation.self) private var nav
    @Environment(\.theme) private var theme
    @State private var info = false

    var body: some View {
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
        .background(theme.c.background)
        .environment(\.imageSource, ImageSource(
            load: { [conn = controller.conn, id = controller.sessionID] key in await conn.image(session: id, key: key) },
            data: { [conn = controller.conn, id = controller.sessionID] key in await conn.imageData(session: id, key: key) }))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.c.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(controller.title)
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.c.heading)
                        .lineLimit(1)
                    Text("Subagent · " + (controller.parent?.title ?? ""))
                        .font(theme.font(.small))
                        .foregroundStyle(theme.c.textMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: 260)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await controller.refresh() }
                } label: {
                    Label(tr("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(controller.refreshing)
                Button { info = true } label: {
                    Label(tr("Session Info"), systemImage: "info.circle")
                }
            }
        }
        .sheet(isPresented: $info) {
            SessionInfoSheet(conn: controller.conn, sessionID: controller.sessionID, currentAgent: controller.agentID)
        }
        .onChange(of: nav.selection) { _, _ in info = false }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
            Text(tr("Read-only: subagents are driven by their parent session.")
                 + (controller.transcriptBusy ? tr(" Parent is running, refreshing every 3 s.") : ""))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(theme.font(.caption))
        .foregroundStyle(theme.c.textMuted)
        .padding(.horizontal, theme.gutter)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(theme.c.surfaceAlt.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(theme.c.border).frame(height: 1) }
    }
}
