import SwiftUI

/// One session in the list, on one line: status, title, time. What it's
/// doing shows on a second line only while it works, waits or failed. Rows
/// with child sessions or subagents have a count at the end that shows them
/// nested below.
struct SessionListRow: View {
    let node: SidebarNode
    let depth: Int
    let expandable: Bool
    let expanded: Bool
    /// SSH session or missing folder: can be read but not sent to.
    var viewOnly = false
    /// The server's name, in areas that mix servers (pinned, groups).
    var serverTag: String? = nil
    let onOpen: () -> Void
    let onToggle: () -> Void
    @Environment(\.theme) private var theme

    /// Leading inset of a row nested `depth` levels down.
    static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 16 }

    private var s: SessionSummary { node.session }
    /// Approvals waiting here, plus in nested sessions while they're hidden.
    private var pending: Int { s.pending + (expanded ? 0 : node.childPending) }
    private var subtasks: Int { node.children.count + (s.subagentCount ?? 0) }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if depth > 0 {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: theme.size(.small)))
                            .foregroundStyle(theme.c.textFaint)
                    }
                    StatusDot(state: s.shownState, live: s.live)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(s.title)
                                .font(theme.font(.body).weight(pending > 0 ? .semibold : .regular))
                                .foregroundStyle(theme.c.text)
                                .lineLimit(1)
                            if node.pinned { marker("pin.fill") }
                            if node.archived { marker("archivebox") }
                            if viewOnly { marker(s.sshHost == nil ? "eye" : "network") }
                            Spacer(minLength: 4)
                            if let serverTag {
                                Text(serverTag)
                                    .font(theme.font(.small))
                                    .foregroundStyle(theme.c.textFaint)
                                    .lineLimit(1)
                                    .padding(.horizontal, 4)
                                    .overlay(Capsule().strokeBorder(theme.c.border))
                                    .fixedSize()
                            }
                            Text(Format.relative(s.updatedAt))
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.c.textFaint)
                                .fixedSize()
                            if pending > 0 {
                                CountBadge(count: pending, tint: theme.c.warning)
                            }
                        }
                        if let detail {
                            Text(detail)
                                .font(theme.font(.caption))
                                .foregroundStyle(detailColor)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            if expandable {
                Button(action: onToggle) {
                    HStack(spacing: 2) {
                        if subtasks > 0 { Text("\(subtasks)").monospacedDigit() }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: theme.size(.small) - 1, weight: .semibold))
                    }
                    .font(theme.font(.small).weight(.medium))
                    .foregroundStyle(expanded ? theme.c.focus : theme.c.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(expanded ? theme.c.focus.opacity(0.14) : theme.c.surfaceAlt))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? tr("Collapse") : tr("Show subtasks"))
            }
        }
        .padding(.leading, Self.indent(depth))
        .accessibilityElement(children: .contain)
    }

    private func marker(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: theme.size(.small)))
            .foregroundStyle(theme.c.textFaint)
    }

    /// What it's doing while it works or waits, or why it failed.
    private var detail: String? {
        if let x = s.hold, x.working { return s.statusText }
        if s.status.isBusy {
            if let a = s.activity, !a.isEmpty { return a }
            return s.status.label
        }
        if s.status == .error { return s.error.flatMap { $0.isEmpty ? nil : $0 } ?? s.status.label }
        return nil
    }

    private var detailColor: Color {
        switch s.shownState {
        case .running, .starting: return theme.c.running
        case .waiting: return theme.c.warning
        case .error: return theme.c.danger
        case .external: return theme.c.external
        case .idle: return theme.c.textMuted
        }
    }
}

/// A subagent nested under its session.
struct SubagentListRow: View {
    let info: SubagentInfo
    let depth: Int
    let onOpen: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: theme.size(.small)))
                    .foregroundStyle(theme.c.textFaint)
                IconTile(icon: "person.2.fill", tint: theme.c.external, size: 18)
                if info.running == true {
                    StatusDot(state: .running, live: true)
                }
                Text(info.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent")
                    .font(theme.font(.callout))
                    .foregroundStyle(theme.c.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let d = info.updatedAt ?? info.startedAt {
                    Text(Format.relative(d))
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.c.textFaint)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .padding(.leading, SessionListRow.indent(depth))
    }
}

/// A list row's own tap feedback (a plain button in a List row has none).
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1)
    }
}

extension View {
    /// Tight rows on the list's own background, like the Mac sidebar.
    func compactRow() -> some View {
        listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// A section header that folds its section: chevron, title, then whatever
/// `trailing` adds (counts, a menu).
struct FoldHeader<Title: View, Trailing: View>: View {
    let expanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let title: () -> Title
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Chevron(expanded: expanded)
                        .frame(width: 12)
                    title()
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .font(theme.font(.caption).weight(.semibold))
        .foregroundStyle(theme.c.textMuted)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 8))
    }
}

/// The "…" at the end of a header.
struct HeaderMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: theme.size(.callout), weight: .semibold))
                .foregroundStyle(theme.c.textMuted)
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
    }
}

/// A server's section header: connection state, name, session count,
/// pending approvals, and its menu.
struct ServerSectionHeader<MenuContent: View>: View {
    let conn: ServerConnection
    /// Mirror copies hidden on this server; left out of the count.
    var hidden: Set<String> = []
    let expanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.theme) private var theme

    var body: some View {
        FoldHeader(expanded: expanded, onToggle: onToggle) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(conn.displayName)
                .lineLimit(1)
            if case .offline(let msg) = conn.status {
                Text(msg)
                    .fontWeight(.regular)
                    .foregroundStyle(theme.c.textFaint)
                    .lineLimit(1)
            } else {
                Text("\(conn.sessions.count - hidden.count)")
                    .fontWeight(.regular)
                    .monospacedDigit()
                    .foregroundStyle(theme.c.textFaint)
            }
        } trailing: {
            if conn.pendingCount > 0 {
                Chip(text: tr("\(conn.pendingCount) pending"), icon: "hand.raised.fill", tint: theme.c.warning)
            }
            HeaderMenu(content: menu)
        }
    }

    private var color: Color {
        switch conn.status {
        case .online: return theme.c.success
        case .connecting: return theme.c.warning
        case .offline: return theme.c.danger
        }
    }
}

/// "Pinned", a group, "Plan Usage": icon, name, count, optional menu.
struct SectionTitle<MenuContent: View>: View {
    let icon: String
    let title: String
    let count: Int?
    let expanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var menu: () -> MenuContent
    @Environment(\.theme) private var theme

    var body: some View {
        FoldHeader(expanded: expanded, onToggle: onToggle) {
            Image(systemName: icon)
                .font(.system(size: theme.size(.small)))
            Text(title)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .fontWeight(.regular)
                    .monospacedDigit()
                    .foregroundStyle(theme.c.textFaint)
            }
        } trailing: {
            if MenuContent.self != EmptyView.self {
                HeaderMenu(content: menu)
            }
        }
    }
}

extension SectionTitle where MenuContent == EmptyView {
    init(icon: String, title: String, count: Int?, expanded: Bool, onToggle: @escaping () -> Void) {
        self.init(icon: icon, title: title, count: count, expanded: expanded, onToggle: onToggle) { EmptyView() }
    }
}

struct EmptyLine: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(theme.c.textFaint)
            .compactRow()
    }
}

/// Drag groups into the order every client shows them in.
struct GroupOrderSheet: View {
    @Environment(SessionOrganizer.self) private var org
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var order: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(order, id: \.self) { g in
                    Label(g, systemImage: "folder")
                        .foregroundStyle(theme.c.text)
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(tr("Group Order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) {
                        org.setGroupOrder(order + org.groupOrder.filter { !order.contains($0) })
                        dismiss()
                    }
                }
            }
            .onAppear {
                order = org.orderedGroups(inUse: store.orderedConnections.reduce(into: Set<String>()) { $0.formUnion($1.groupNames) })
            }
        }
    }
}

/// Shown until a server is added.
struct WelcomeCard: View {
    let onAdd: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(icon: "server.rack", tint: theme.c.focus, size: 44)
            Text(tr("Welcome to Binary"))
                .font(theme.font(.title))
                .foregroundStyle(theme.c.heading)
            Text(tr("Binary follows and drives Claude Code sessions on your Mac or servers through binaryd. Add a server to start: run `binaryd token` on it, copy what it prints, and paste it in."))
                .font(theme.font(.callout))
                .foregroundStyle(theme.c.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("The phone has to reach the server: over Tailscale (tailscale serve gives it an HTTPS address), a VPN or your local network."))
                .font(theme.font(.caption))
                .foregroundStyle(theme.c.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("Add Server"), action: onAdd)
                .buttonStyle(.themed(.primary))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(.vertical, 8)
    }
}
