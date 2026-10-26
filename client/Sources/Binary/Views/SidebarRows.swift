import AppKit
import SwiftUI

struct ServerHeader: View {
    let conn: ServerConnection
    var collapsed = false
    var searching = false
    /// Mirror copies hidden on this server; left out of the counts.
    var hidden: Set<String> = []
    var multipleServers = false
    var onToggle: () -> Void = {}
    var onCollapseOthers: () -> Void = {}
    var onExpandAll: () -> Void = {}
    var onNewGroup: () -> Void = {}
    @Environment(\.theme) private var theme
    @State private var hover = false

    /// Sessions with a turn running, here or in another program.
    private var busy: Int { conn.sessions.values.filter { ($0.shownState.isBusy || $0.shownState == .external) && !hidden.contains($0.id) }.count }
    private var total: Int { conn.sessions.count - hidden.count }

    var body: some View {
        HStack(spacing: 7) {
            Chevron(expanded: !collapsed || searching)
                .frame(width: 10)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(conn.displayName)
                .font(theme.font(.caption).weight(.semibold))
                .foregroundStyle(theme.c.textMuted)
                .lineLimit(1)
            if case .offline(let msg) = conn.status {
                Text(msg)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textFaint)
                    .lineLimit(1)
            }
            if collapsed {
                // Folded: still say how much is there and what's going on.
                Text("\(total)")
                    .font(theme.font(.caption).monospacedDigit())
                    .foregroundStyle(theme.c.textFaint)
                    .help(tr("\(total) sessions"))
                if busy > 0 {
                    HStack(spacing: 3) {
                        StatusDot(state: .running, live: true)
                        Text("\(busy)").monospacedDigit()
                    }
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.running)
                    .help(tr("\(busy) running"))
                }
            }
            Spacer(minLength: 4)
            if conn.pendingCount > 0 {
                Chip(text: tr("\(conn.pendingCount) pending"), icon: "hand.raised.fill", tint: theme.c.warning)
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(theme.c.textFaint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous).fill(hover ? theme.c.text.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onToggle)
        .contextMenu { menuItems }
        .help(help)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(conn.displayName + (collapsed ? tr(", collapsed") : tr(", expanded")))
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(collapsed ? tr("Expand") : tr("Collapse"), action: onToggle)
        if multipleServers {
            Button(tr("Collapse Others"), action: onCollapseOthers)
            Button(tr("Expand All"), action: onExpandAll)
        }
        Divider()
        Button(tr("Reconnect")) { conn.reconnect() }
        Button(tr("New Group…"), action: onNewGroup)
    }

    private var color: Color {
        switch conn.status {
        case .online: return theme.c.success
        case .connecting: return theme.c.warning
        case .offline: return theme.c.danger
        }
    }

    private var help: String {
        var parts = [conn.config.url]
        if !hidden.isEmpty {
            parts.append(tr("\(hidden.count) copies of sessions another server runs are hidden"))
        }
        if let info = conn.info {
            parts.append("\(info.hostname) · \(info.os)/\(info.arch) · claude \(info.claudeVersion) · binaryd \(info.version)")
        }
        return parts.joined(separator: "\n")
    }
}

/// "Pinned" / "Ungrouped" labels; sessions can be dropped on them.
struct SectionLabel: View {
    let title: String
    let icon: String
    let count: Int
    let onDrop: ([String]) -> Bool
    @Environment(\.theme) private var theme
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: theme.size(.small)))
                .frame(width: 14)
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(theme.c.textFaint)
            Spacer()
        }
        .font(theme.font(.caption).weight(.medium))
        .foregroundStyle(theme.c.textMuted)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .background(RoundedRectangle(cornerRadius: theme.rowRadius).fill(targeted ? theme.c.selection.opacity(0.6) : .clear))
        .dropDestination(for: String.self) { items, _ in onDrop(items) } isTargeted: { targeted = $0 }
    }
}

struct GroupHeader<MenuContent: View>: View {
    let name: String
    let count: Int
    let collapsed: Bool
    let payload: String
    /// Shows a + that starts a new session in this group.
    var onNew: (() -> Void)? = nil
    /// For a group being dragged over this one: where it would land.
    var insertEdge: (_ dragged: String) -> VerticalEdge? = { _ in nil }
    /// Sessions are being dragged over one of this group's rows.
    var highlighted = false
    let onToggle: () -> Void
    let onDrop: ([String]) -> Bool
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.theme) private var theme
    @State private var hover = false
    @State private var targeted = false
    /// Set while another group is dragged over this one: an insertion line, not "add to".
    @State private var lineEdge: VerticalEdge?

    private var joining: Bool { (targeted && lineEdge == nil) || highlighted }

    var body: some View {
        HStack(spacing: 6) {
            Chevron(expanded: !collapsed)
                .frame(width: 14)
            Text(name)
                .font(theme.font(.callout).weight(.semibold))
                .foregroundStyle(theme.c.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let onNew {
                AddButton(action: onNew, rowHover: hover)
                    .help(tr("New Session in \(name)"))
            }
            CountBadge(count: count)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                .fill(joining ? theme.c.selection : hover ? theme.c.hover : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                .strokeBorder(joining ? theme.c.focus : .clear, lineWidth: 1.5)
        )
        .overlay(alignment: lineEdge == .bottom ? .bottom : .top) {
            if targeted, lineEdge != nil {
                Capsule().fill(theme.c.focus)
                    .frame(height: 2.5)
                    .offset(y: lineEdge == .bottom ? 3 : -3)
            }
        }
        .padding(.top, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onToggle)
        .contextMenu { menu() }
        .draggable(payload) {
            Label(name, systemImage: "folder.fill")
                .padding(6)
        }
        .dropDestination(for: String.self) { items, _ in onDrop(items) } isTargeted: { on in
            // What is being dragged decides the hint: a group gets a line where it
            // would go, sessions get the whole header (they join the group).
            if on, let text = NSPasteboard(name: .drag).string(forType: .string),
               case .group(_, let dragged) = DragPayload(text) {
                lineEdge = insertEdge(dragged)
            } else {
                lineEdge = nil
            }
            targeted = on
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tr("Group \(name), \(count) sessions, \(collapsed ? tr("collapsed") : tr("expanded"))"))
    }
}

/// A project's header when grouping by project: like a group's, but its
/// members come from their folder, so nothing is dragged onto it.
struct ProjectHeader<MenuContent: View>: View {
    let name: String
    let folder: String
    let count: Int
    let collapsed: Bool
    /// Sessions with a turn running; shown while folded, as on servers.
    var busy = 0
    var onNew: (() -> Void)? = nil
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Chevron(expanded: !collapsed)
                .frame(width: 14)
            Text(name)
                .font(theme.font(.callout).weight(.semibold))
                .foregroundStyle(theme.c.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let onNew {
                AddButton(action: onNew, rowHover: hover)
                    .help(tr("New Session in \(name)"))
            }
            if collapsed && busy > 0 {
                HStack(spacing: 3) {
                    StatusDot(state: .running, live: true)
                    Text("\(busy)").monospacedDigit()
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.c.running)
                .help(tr("\(busy) running"))
            }
            CountBadge(count: count)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                .fill(hover ? theme.c.hover : .clear)
        )
        .padding(.top, 4)
        .contentShape(Rectangle())
        .help(folder)
        .onHover { hover = $0 }
        .onTapGesture(perform: onToggle)
        .contextMenu { menu() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tr("Project \(name), \(count) sessions, \(collapsed ? tr("collapsed") : tr("expanded"))"))
    }
}

/// Geometry shared by rows so nested rows line up under their parent.
enum TreeMetrics {
    /// A top-level row's title starts here (padding + chevron + dot).
    static let titleX: CGFloat = 42
    /// Each level indents the title this much, like Claude desktop's sidebar.
    static let step: CGFloat = 24
    /// x of the connector line for rows at `depth` (1 = child of a top-level
    /// row): just right of where the parent's title starts.
    static func lineX(_ depth: Int) -> CGFloat { titleX + 5 + CGFloat(max(depth - 1, 0)) * step }
    /// Leading inset of a nested row's content, so its title starts one step in.
    static func contentX(_ depth: Int) -> CGFloat { titleX + CGFloat(depth) * step - 2 }
}

/// The thin line joining a nested row to its parent: straight down for rows
/// with siblings below, ending in a rounded "╰" corner on the last one.
struct TreeConnector: Shape {
    var isLast: Bool
    var x: CGFloat
    var radius: CGFloat = 5
    var reach: CGFloat = 11

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY
        p.move(to: CGPoint(x: x, y: rect.minY))
        p.addLine(to: CGPoint(x: x, y: mid - radius))
        p.addQuadCurve(to: CGPoint(x: x + radius, y: mid), control: CGPoint(x: x, y: mid))
        p.addLine(to: CGPoint(x: x + reach, y: mid))
        if !isLast {
            p.move(to: CGPoint(x: x, y: mid - radius))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return p
    }
}

/// Where a nested row sits among its siblings, for drawing connectors.
struct TreePosition: Equatable {
    var depth: Int
    var isLast: Bool
    /// For each ancestor level above this one, whether a line continues past it.
    var continues: [Bool] = []
}

struct SessionRow: View {
    let node: SidebarNode
    let position: TreePosition
    let expandable: Bool
    let expanded: Bool
    let batched: Bool
    /// SSH session or missing folder: can be read but not sent to.
    var viewOnly = false
    /// The server's name, in areas that mix servers (pinned, groups).
    var serverTag: String? = nil
    let onToggle: () -> Void
    @Environment(\.theme) private var theme
    @Environment(Navigation.self) private var nav
    @State private var hover = false

    /// Read here, not passed in, so selecting re-renders just the rows involved.
    private var selected: Bool { nav.selection == node.ref }
    private var s: SessionSummary { node.session }
    private var lit: Bool { selected || batched }
    private var nested: Bool { position.depth > 0 }

    /// Approvals waiting here, plus in nested sessions while they're hidden.
    private var pending: Int { s.pending + (expanded ? 0 : node.childPending) }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if nested {
                Color.clear.frame(width: TreeMetrics.contentX(position.depth) - 6, height: 1)
            }
            disclosure
            if !nested {
                StatusDot(state: s.shownState, live: s.live, background: s.hasBackgroundWork)
            }
            Text(s.title)
                .font(theme.font(.rowTitle).weight(selected ? .medium : .regular))
                .foregroundStyle(lit ? theme.c.selectionText : (nested ? theme.c.text.opacity(0.92) : theme.c.text))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if node.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: theme.size(.small)))
                    .foregroundStyle(lit ? theme.c.selectionText.opacity(0.8) : theme.c.textFaint)
            }
            if node.archived {
                Image(systemName: "archivebox")
                    .font(.system(size: theme.size(.small)))
                    .foregroundStyle(lit ? theme.c.selectionText.opacity(0.8) : theme.c.textFaint)
            }
            if viewOnly {
                Image(systemName: s.sshHost == nil ? "eye" : "network")
                    .font(.system(size: theme.size(.small)))
                    .foregroundStyle(lit ? theme.c.selectionText.opacity(0.8) : theme.c.textFaint)
                    .help(s.sshHost.map { tr("View only · SSH on \($0)") } ?? tr("View only · folder no longer exists"))
            }
            if let serverTag {
                Text(serverTag)
                    .font(theme.font(.small))
                    .foregroundStyle(lit ? theme.c.selectionText.opacity(0.8) : theme.c.textFaint)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(lit ? theme.c.selectionText.opacity(0.35) : theme.c.border))
                    .fixedSize()
            }
            Text(Format.relative(s.updatedAt, short: true))
                .font(theme.font(.rowMeta))
                .foregroundStyle(lit ? theme.c.selectionText.opacity(0.72) : (nested ? theme.c.textFaint : theme.c.textMuted))
                .fixedSize()
            if pending > 0 {
                CountBadge(count: pending, tint: theme.c.warning)
            } else if nested {
                // Nested rows: a small, quiet dot at the end.
                Circle().fill(nestedDotColor)
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 2)
                    .help(s.shownState != .idle ? s.statusText
                          : s.hasBackgroundWork ? tr("Idle · background tasks running")
                          : s.live ? tr("Idle · process running") : s.statusText)
            }
        }
        .padding(.vertical, nested ? 4 : 6)
        .padding(.trailing, 8)
        .padding(.leading, 2)
        .frame(minHeight: nested ? 26 : 30)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .fill(background)
                if nested { connectors }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var disclosure: some View {
        if expandable {
            Button(action: onToggle) {
                Chevron(expanded: expanded, color: lit ? theme.c.selectionText.opacity(0.8) : nil)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? tr("Collapse") : tr("Show subtasks"))
        } else if !nested {
            Color.clear.frame(width: 14, height: 18)
        }
    }

    private var connectors: some View {
        TreeLines(position: position, color: lit ? theme.c.selectionText.opacity(0.45) : theme.c.borderStrong)
    }

    private var nestedDotColor: Color {
        switch s.shownState {
        case .running, .starting: return theme.c.running.opacity(0.8)
        case .waiting: return theme.c.warning
        case .error: return theme.c.danger.opacity(0.8)
        case .external: return theme.c.external.opacity(0.85)
        default:
            if s.hasBackgroundWork { return theme.c.success.opacity(0.85) }
            return lit ? theme.c.selectionText.opacity(0.6) : theme.c.textFaint.opacity(s.live ? 0.9 : 0.55)
        }
    }

    private var background: Color {
        if selected { return theme.c.selection }
        if batched { return theme.c.selection.opacity(0.6) }
        if hover { return theme.c.hover }
        return .clear
    }

    /// Details that no longer take a line in the row.
    private var tooltip: String {
        var lines = [s.title, Format.path(s.cwd, cwd: nil)]
        if viewOnly {
            lines.append(s.sshHost.map { tr("View only · SSH on \($0)") } ?? tr("View only · folder no longer exists"))
        }
        if let held = s.holdText { lines.append(held) }
        if let a = s.activity, !a.isEmpty { lines.append(a) } else if s.status == .external && s.hold == nil { lines.append(s.statusText) }
        if s.status == .error, let e = s.error, !e.isEmpty { lines.append(e) }
        if let n = s.subagentCount, n > 0 { lines.append(tr("\(n) subagents")) }
        if !node.children.isEmpty { lines.append(tr("\(node.children.count) child sessions")) }
        lines.append(Format.relative(s.updatedAt))
        return lines.joined(separator: "\n")
    }
}

/// Connector lines for one nested row: its own "╰"/"├" joint plus the
/// pass-through lines of ancestor levels that have more rows below.
struct TreeLines: View {
    let position: TreePosition
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(position.continues.enumerated()), id: \.offset) { i, goesOn in
                if goesOn {
                    Path { p in
                        let x = TreeMetrics.lineX(i + 1)
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: 1000))
                    }
                    .stroke(color, lineWidth: 1)
                }
            }
            TreeConnector(isLast: position.isLast, x: TreeMetrics.lineX(position.depth))
                .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        .clipped()
    }
}

struct SubagentRow: View {
    let info: SubagentInfo
    let ref: SessionRef
    let position: TreePosition
    @Environment(\.theme) private var theme
    @Environment(Navigation.self) private var nav
    @State private var hover = false

    private var selected: Bool { nav.selection == ref }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: TreeMetrics.contentX(position.depth) - 6, height: 1)
            Text(info.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent")
                .font(theme.font(.rowTitle))
                .foregroundStyle(selected ? theme.c.selectionText : theme.c.text.opacity(0.92))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let t = info.updatedAt ?? info.startedAt {
                Text(Format.relative(t, short: true))
                    .font(theme.font(.rowMeta))
                    .foregroundStyle(selected ? theme.c.selectionText.opacity(0.72) : theme.c.textFaint)
                    .fixedSize()
            }
            // Marks a subagent where nested sessions show their status dot.
            Image(systemName: "person.2")
                .font(.system(size: theme.size(.small) - 1))
                .foregroundStyle(selected ? theme.c.selectionText.opacity(0.7) : theme.c.textFaint.opacity(0.8))
            if info.running == true {
                StatusDot(state: .running, live: true)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 8)
        .padding(.leading, 2)
        .frame(minHeight: 26)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .fill(selected ? theme.c.selection : hover ? theme.c.hover : .clear)
                TreeLines(position: position, color: selected ? theme.c.selectionText.opacity(0.45) : theme.c.borderStrong)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help([info.title,
               info.entries.map { tr("\($0) entries") },
               info.startedAt.map { tr("Started ") + $0.formatted(Date.FormatStyle().month().day().hour().minute().locale(Format.locale)) },
               tr("Subagent · read-only")].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A message that matched the search, under its session's row; clicking it
/// opens the session there.
struct SnippetRow: View {
    let snippet: ContentHit.Snippet
    let query: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: snippet.role == "user" ? "person" : "sparkle")
                    .font(.system(size: theme.size(.small) - 1))
                    .foregroundStyle(theme.c.textFaint)
                    .frame(width: 12)
                Text(snippet.highlighted(query))
                    .font(theme.font(.rowMeta))
                    .foregroundStyle(hover ? theme.c.text : theme.c.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, TreeMetrics.titleX - 18)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous).fill(hover ? theme.c.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(snippet.time.map { $0.formatted(Date.FormatStyle().month().day().hour().minute().locale(Format.locale)) } ?? "")
    }
}

/// Says how many mirror copies a server hides, with a way to show them.
struct HiddenMirrorsLine: View {
    let count: Int
    let hosts: [String]
    let onShow: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: theme.size(.small)))
                Text(tr("\(count) copies hidden"))
                    .lineLimit(1)
                Text(tr("Show"))
                    .foregroundStyle(hover ? theme.c.text : theme.c.focus)
            }
            .font(theme.font(.rowMeta))
            .foregroundStyle(theme.c.textFaint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tr("View-only copies Claude desktop keeps on this Mac of sessions that run on \(hosts.joined(separator: tr(", "))). They're listed under that server."))
    }
}

/// "Show all N" at the end of a long nested list.
struct MoreRow: View {
    let text: String
    let position: TreePosition
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Color.clear.frame(width: TreeMetrics.contentX(position.depth) - 6, height: 1)
                Text(text)
                    .font(theme.font(.rowMeta).weight(.medium))
                    .foregroundStyle(hover ? theme.c.text : theme.c.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.leading, 2)
            .frame(minHeight: 24)
            .background(alignment: .leading) {
                TreeLines(position: position, color: theme.c.borderStrong)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct DragPreview: View {
    let title: String
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
            Text(count > 1 ? tr("\(count) sessions") : title).lineLimit(1)
        }
        .font(theme.font(.callout).weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(theme.c.surface))
        .foregroundStyle(theme.c.text)
    }
}

/// The + on a group header: its own hover background (darker than the header's,
/// which is hovered too), so it reads as a button.
private struct AddButton: View {
    let action: () -> Void
    let rowHover: Bool
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: theme.size(.caption), weight: .semibold))
                .foregroundStyle(hover ? theme.c.text : rowHover ? theme.c.textMuted : theme.c.textFaint)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hover ? theme.c.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}


/// Lets sessions be dropped anywhere in a group, not just on its header:
/// each row reports while it is under the drag so the whole group lights up.
struct GroupDropZone: ViewModifier {
    let key: String
    @Binding var hovered: Set<String>
    let active: Bool
    let onDrop: ([String]) -> Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .fill(active ? theme.c.selection.opacity(0.45) : .clear)
                    .allowsHitTesting(false)
            )
            .dropDestination(for: String.self) { items, _ in
                hovered.remove(key)
                return onDrop(items)
            } isTargeted: { on in
                if on { hovered.insert(key) } else { hovered.remove(key) }
            }
    }
}
