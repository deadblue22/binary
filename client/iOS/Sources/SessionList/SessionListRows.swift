import SwiftUI

/// One session in the list, always on two lines so the list doesn't shift
/// as sessions start and stop: the title, then the server, the project and
/// what it's doing (while it works, waits or failed), with the time and
/// counts at the end. Nested sessions take one line. Its state shows as a
/// stripe on the screen's edge (`sessionRow`). Rows with child sessions or
/// subagents have a count that shows them nested below.
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
    static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 6 }

    /// Space above and below the text of a two-line row.
    private static let padding: CGFloat = 11

    private var s: SessionSummary { node.session }
    /// Approvals waiting here, plus in nested sessions while they're hidden.
    private var pending: Int { s.pending + (expanded ? 0 : node.childPending) }
    private var subtasks: Int { node.children.count + (s.subagentCount ?? 0) }
    private var nested: Bool { depth > 0 }

    var body: some View {
        Button(action: onOpen) {
            Group {
                if nested { oneLine } else { twoLines }
            }
            .padding(.leading, Self.indent(depth))
            .padding(.trailing, 12)
            .padding(.vertical, nested ? 12 : Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        // The count sits over its own placeholder in the row, with a tap
        // area that reaches the row's bottom and the screen's edge.
        .overlay(alignment: nested ? .trailing : .bottomTrailing) {
            if expandable {
                Button(action: onToggle) {
                    subtaskCount
                        .padding(.leading, 10)
                        .padding(.trailing, 12)
                        .padding(.top, nested ? 12 : 14)
                        .padding(.bottom, nested ? 12 : Self.padding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? tr("Collapse") : tr("Show subtasks"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                title(theme.font(.body))
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if let serverTag {
                    Text(serverTag)
                        .font(theme.font(.small))
                        .foregroundStyle(theme.c.textFaint)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .overlay(Capsule().strokeBorder(theme.c.border))
                        .fixedSize()
                }
                secondLine
                    .font(theme.font(.caption))
                    .lineLimit(1)
                Spacer(minLength: 6)
                ends
            }
        }
    }

    private var oneLine: some View {
        HStack(spacing: 6) {
            title(theme.font(.callout))
            Spacer(minLength: 6)
            ends
        }
    }

    @ViewBuilder
    private func title(_ font: Font) -> some View {
        Text(s.title)
            .font(font.weight(pending > 0 ? .semibold : .regular))
            .foregroundStyle(theme.c.text)
            .lineLimit(1)
        if node.pinned { marker("pin.fill") }
        if node.archived { marker("archivebox") }
        if viewOnly { marker(s.sshHost == nil ? "eye" : "network") }
    }

    /// Time, approvals waiting, and room for the subtask count.
    @ViewBuilder
    private var ends: some View {
        Text(Format.relative(s.updatedAt))
            .font(theme.font(.caption))
            .foregroundStyle(theme.c.textFaint)
            .fixedSize()
        if pending > 0 {
            CountBadge(count: pending, tint: theme.c.warning)
        }
        if expandable {
            subtaskCount.hidden()
        }
    }

    private var subtaskCount: some View {
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
    }

    @ViewBuilder
    private var secondLine: some View {
        if let detail {
            Text("\(Text(project).foregroundStyle(theme.c.textFaint)) · \(Text(detail).foregroundStyle(detailColor))")
        } else {
            Text(project).foregroundStyle(theme.c.textFaint)
        }
    }

    /// The folder's name, readable: a worktree under `<repo>/.claude/worktrees`
    /// shows its repository instead of its generated name; other generated
    /// names drop their hash.
    private var project: String {
        var folder = s.project.isEmpty ? (s.cwd as NSString).lastPathComponent : s.project
        if let r = s.cwd.range(of: "/.claude/worktrees/") {
            folder = (String(s.cwd[..<r.lowerBound]) as NSString).lastPathComponent
        } else if let r = folder.range(of: #"-(?=[0-9a-f]*[0-9])[0-9a-f]{6}$"#, options: .regularExpression) {
            // Generated folders like scratch-2026-10-10-35992a lose the hash.
            folder.removeSubrange(r)
        }
        return folder
    }

    private func marker(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: theme.size(.small)))
            .foregroundStyle(theme.c.textFaint)
    }

    /// What it's doing while it works or waits, or why it failed.
    private var detail: String? {
        if let x = s.hold, x.working { return s.statusText }
        if s.shownState != .idle && !s.status.isBusy && s.status != .error {
            // Only background subagents keep it working.
            return s.statusText
        }
        if s.status.isBusy {
            if let a = s.activity, !a.isEmpty { return a }
            return s.status.label
        }
        if s.status == .error { return s.error.flatMap { $0.isEmpty ? nil : $0 } ?? s.status.label }
        let bg = s.busyTasks.count
        return bg > 0 ? tr("\(bg) background task\(bg == 1 ? "" : "s")") : nil
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
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: theme.size(.small)))
                    .foregroundStyle(theme.c.external)
                Text(info.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent")
                    .font(theme.font(.callout))
                    .foregroundStyle(theme.c.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let d = info.updatedAt ?? info.startedAt {
                    Text(Format.relative(d))
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.c.textFaint)
                        .fixedSize()
                }
            }
            .padding(.leading, SessionListRow.indent(depth))
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// A message that matched the search, under its session; tapping it opens
/// the session there.
struct SnippetListRow: View {
    let snippet: ContentHit.Snippet
    let query: String
    let depth: Int
    let onOpen: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: snippet.role == "user" ? "person" : "sparkle")
                    .font(.system(size: theme.size(.small) - 1))
                    .foregroundStyle(theme.c.textFaint)
                    .frame(width: 14)
                Text(snippet.highlighted(query))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .padding(.leading, SessionListRow.indent(depth) + 4)
    }
}

/// A list row's own tap feedback (a plain button in a List row has none).
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// A session's state on the screen's edge: blue (pulsing) while it works,
/// orange while it waits for you, red after an error; while idle, green when
/// a background task still runs, faint green when the process is merely
/// open, nothing when it is closed.
struct StatusStripe: View {
    let state: SessionState?
    var live = false
    /// Idle, but background tasks still run (`SessionSummary.hasBackgroundWork`).
    var background = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color? {
        switch state {
        case nil: return nil
        case .idle?: return background ? theme.c.success : live ? theme.c.success.opacity(0.3) : nil
        case let s?: return s.color(theme)
        }
    }

    private var pulsing: Bool { !reduceMotion && (state == .running || state == .starting || state == .external) }

    var body: some View {
        HStack(spacing: 0) {
            if let color {
                Group {
                    if pulsing {
                        BreathingBar(color: color)
                    } else {
                        UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2).fill(color)
                    }
                }
                .frame(width: 4)
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }
}

/// The stripe of a working session, its opacity breathing in a Core
/// Animation layer: a SwiftUI repeating animation would re-render the list
/// every frame while anything runs (see `PulseRing`).
private struct BreathingBar: UIViewRepresentable {
    let color: Color

    func makeUIView(context: Context) -> BreathingBarView { BreathingBarView() }

    func updateUIView(_ view: BreathingBarView, context: Context) {
        view.backgroundColor = UIColor(color)
    }
}

final class BreathingBarView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 2
        layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layer.removeAllAnimations()
        guard window != nil else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.35
        breathe.duration = 0.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breathe, forKey: "breathe")
    }
}

/// A session or subagent row: edge to edge, with its state on the leading
/// edge and hairlines between rows.
private struct SessionRowStyle: ViewModifier {
    let state: SessionState?
    let live: Bool
    let background: Bool
    let bottomSeparator: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
            .listRowBackground(StatusStripe(state: state, live: live, background: background))
            .listRowSeparator(.visible, edges: .top)
            .listRowSeparator(bottomSeparator ? .visible : .hidden, edges: .bottom)
            .listRowSeparatorTint(theme.c.border)
    }
}

extension View {
    /// A session or subagent row; `bottomSeparator: false` keeps what
    /// follows (search matches) attached to it.
    func sessionRow(state: SessionState?, live: Bool = false, background: Bool = false, bottomSeparator: Bool = true) -> some View {
        modifier(SessionRowStyle(state: state, live: live, background: background, bottomSeparator: bottomSeparator))
    }

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
    /// Sessions with a turn running; shown while folded.
    var busy = 0
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
            if !expanded && busy > 0 {
                HStack(spacing: 3) {
                    StatusDot(state: .running, live: true)
                    Text("\(busy)").fontWeight(.regular).monospacedDigit()
                }
                .foregroundStyle(theme.c.running)
            }
        } trailing: {
            if MenuContent.self != EmptyView.self {
                HeaderMenu(content: menu)
            }
        }
    }
}

extension SectionTitle where MenuContent == EmptyView {
    init(icon: String, title: String, count: Int?, expanded: Bool, busy: Int = 0, onToggle: @escaping () -> Void) {
        self.init(icon: icon, title: title, count: count, expanded: expanded, busy: busy, onToggle: onToggle) { EmptyView() }
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
