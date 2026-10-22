import SwiftUI

/// One session in the list: status, title and time, then what it's doing (or
/// its project) on a second line. Rows with child sessions or subagents have
/// a count at the end that shows them nested below.
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
    static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 18 }

    private var s: SessionSummary { node.session }
    /// Approvals waiting here, plus in nested sessions while they're hidden.
    private var pending: Int { s.pending + (expanded ? 0 : node.childPending) }
    private var subtasks: Int { node.children.count + (s.subagentCount ?? 0) }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 10) {
                    if depth > 0 {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: theme.size(.caption)))
                            .foregroundStyle(theme.c.textFaint)
                    }
                    StatusDot(state: s.shownState, live: s.live)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.title)
                                .font(theme.font(.body).weight(pending > 0 ? .semibold : .regular))
                                .foregroundStyle(theme.c.text)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Format.relative(s.updatedAt))
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.c.textFaint)
                                .fixedSize()
                        }
                        HStack(spacing: 5) {
                            if node.pinned { Image(systemName: "pin.fill").foregroundStyle(theme.c.textFaint) }
                            if node.archived { Image(systemName: "archivebox").foregroundStyle(theme.c.textFaint) }
                            if viewOnly {
                                Image(systemName: s.sshHost == nil ? "eye" : "network").foregroundStyle(theme.c.textFaint)
                            }
                            Text(detail)
                                .foregroundStyle(detailColor)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let serverTag {
                                Text(serverTag)
                                    .font(theme.font(.small))
                                    .foregroundStyle(theme.c.textFaint)
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .overlay(Capsule().strokeBorder(theme.c.border))
                                    .fixedSize()
                            }
                            if pending > 0 {
                                CountBadge(count: pending, tint: theme.c.warning)
                            }
                        }
                        .font(theme.font(.caption))
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            if expandable {
                Button(action: onToggle) {
                    HStack(spacing: 3) {
                        if subtasks > 0 { Text("\(subtasks)").monospacedDigit() }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: theme.size(.small), weight: .semibold))
                    }
                    .font(theme.font(.caption).weight(.medium))
                    .foregroundStyle(expanded ? theme.c.focus : theme.c.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(expanded ? theme.c.focus.opacity(0.14) : theme.c.surfaceAlt))
                    .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? tr("Collapse") : tr("Show subtasks"))
            }
        }
        .padding(.leading, Self.indent(depth))
        .accessibilityElement(children: .contain)
    }

    /// What it's doing when busy, the error when it failed, else where it is.
    private var detail: String {
        if let x = s.hold, x.working { return s.statusText }
        if s.status.isBusy, let a = s.activity, !a.isEmpty { return a }
        if s.status.isBusy { return s.status.label }
        if s.status == .error, let e = s.error, !e.isEmpty { return e }
        let place = s.project.isEmpty ? (s.cwd as NSString).lastPathComponent : s.project
        if let b = s.gitBranch, !b.isEmpty, b != "HEAD", s.worktree != nil { return place + " · " + b }
        return place
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
            HStack(spacing: 10) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: theme.size(.caption)))
                    .foregroundStyle(theme.c.textFaint)
                IconTile(icon: "person.2.fill", tint: theme.c.external, size: 20)
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
            .padding(.vertical, 2)
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

/// A server's section header: connection state, name, pending approvals.
struct ServerSectionHeader<MenuContent: View>: View {
    let conn: ServerConnection
    /// Mirror copies hidden on this server; left out of the count.
    var hidden: Set<String> = []
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(conn.displayName)
                .font(theme.font(.headline))
                .foregroundStyle(theme.c.text)
                .lineLimit(1)
            if case .offline(let msg) = conn.status {
                Text(msg)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textFaint)
                    .lineLimit(1)
            } else {
                Text("\(conn.sessions.count - hidden.count)")
                    .font(theme.font(.caption).monospacedDigit())
                    .foregroundStyle(theme.c.textFaint)
            }
            Spacer(minLength: 4)
            if conn.pendingCount > 0 {
                Chip(text: tr("\(conn.pendingCount) pending"), icon: "hand.raised.fill", tint: theme.c.warning)
            }
            Menu(content: menu) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: theme.size(.body)))
                    .foregroundStyle(theme.c.textMuted)
            }
        }
        .textCase(nil)
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
    @ViewBuilder var menu: () -> MenuContent
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: theme.size(.caption)))
                .foregroundStyle(theme.c.textMuted)
            Text(title)
                .font(theme.font(.headline))
                .foregroundStyle(theme.c.text)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(theme.font(.caption).monospacedDigit())
                    .foregroundStyle(theme.c.textFaint)
            }
            Spacer(minLength: 4)
            if MenuContent.self != EmptyView.self {
                Menu(content: menu) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: theme.size(.body)))
                        .foregroundStyle(theme.c.textMuted)
                }
            }
        }
        .textCase(nil)
    }
}

extension SectionTitle where MenuContent == EmptyView {
    init(icon: String, title: String, count: Int?) {
        self.init(icon: icon, title: title, count: count) { EmptyView() }
    }
}

struct EmptyLine: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(theme.c.textFaint)
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
