import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The right-hand panel: where a session runs, how it is organized, what it
/// has used, and the sessions and subagents it started.
struct SessionInspector: View {
    let conn: ServerConnection
    let sessionID: String
    var connected = true
    /// The subagent being viewed, when the detail shows one.
    var currentAgent: String? = nil
    var onRename: (() -> Void)? = nil

    @Environment(SessionOrganizer.self) private var org
    @Environment(Navigation.self) private var nav
    @Environment(\.theme) private var theme
    @State private var notice: String?
    @State private var newGroup = false
    @State private var groupName = ""

    private var s: SessionSummary? { conn.sessions[sessionID] }
    private var ref: SessionRef { SessionRef(server: conn.id, session: sessionID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let s {
                    sessionCard(s)
                    if s.live { processCard(s) }
                    organizeCard(s)
                    usageCard(s)
                    tasksCard(s)
                    actionsCard(s)
                } else {
                    Text(tr("This session is no longer on the server."))
                        .font(theme.font(.callout))
                        .foregroundStyle(theme.c.textMuted)
                }
            }
            .padding(12)
            .slimScrollers()
        }
        .fillAvailable()
        // Same ground as the conversation; the cards' own fill sets them apart.
        .background(theme.c.background)
        .task(id: s?.subagentCount ?? 0) {
            if (s?.subagentCount ?? 0) > 0 { await conn.loadSubagents(sessionID) }
        }
        .alert(tr("New Group"), isPresented: $newGroup) {
            TextField(tr("Group name"), text: $groupName)
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Create")) {
                let g = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !g.isEmpty { setGroup(g) }
            }
        }
    }

    // MARK: Cards

    private func sessionCard(_ s: SessionSummary) -> some View {
        InspectorCard(title: tr("Session")) {
            HStack(spacing: 8) {
                StatusPill(state: s.shownState, live: s.live, hold: s.hold)
                if s.live, let pid = s.pid {
                    Text("pid " + String(pid))
                        .font(theme.mono(theme.size(.small)))
                        .foregroundStyle(theme.c.textFaint)
                }
                Spacer()
                if !connected {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(theme.c.warning)
                }
            }
            if let a = s.activity, !a.isEmpty {
                InfoRow(icon: "waveform", label: tr("Activity"), value: a)
            }
            if let h = s.hold {
                InfoRow(icon: h.icon, label: tr("Held by"), value: h.shortName + " · " + h.activityName)
            }
            if s.status == .error, let e = s.error, !e.isEmpty {
                Text(e)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let host = s.sshHost {
                InfoRow(icon: "network", label: tr("Location"), value: "SSH · " + host)
            } else if conn.isViewOnly(s) {
                InfoRow(icon: "questionmark.folder", label: tr("Location"), value: tr("Folder no longer exists"))
            }
            if let w = s.worktree, !w.isEmpty {
                InfoRow(icon: "square.stack.3d.up", label: "Worktree", value: Format.path(w, cwd: nil), mono: true, help: w)
            }
            InfoRow(icon: "server.rack", label: tr("Server"), value: conn.displayName,
                    help: ([conn.config.url] + (conn.info.map { ["\($0.hostname) · \($0.os)/\($0.arch) · binaryd \($0.version)"] } ?? [])).joined(separator: "\n"))
            InfoRow(icon: "folder", label: tr("Directory"), value: Format.path(s.cwd, cwd: nil), mono: true, help: s.cwd) {
                Button { copy(s.cwd) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.icon(size: 20))
                    .help(tr("Copy path"))
                #if os(macOS)
                if conn.isLocal {
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.icon(size: 20))
                        .help(tr("Show in Finder"))
                }
                #endif
            }
            if let b = s.gitBranch, !b.isEmpty, b != "HEAD" {
                InfoRow(icon: "arrow.triangle.branch", label: tr("Branch"), value: b, mono: true)
            }
            InfoRow(icon: "number", label: "ID", value: String(s.id.prefix(8)) + "…", mono: true, help: s.id) {
                Button { copy(s.id) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.icon(size: 20))
                    .help(tr("Copy session ID"))
            }
            if let e = s.entrypoint, !e.isEmpty {
                InfoRow(icon: "app.connected.to.app.below.fill", label: tr("Source"), value: e)
            }
        }
    }

    /// What keeps the process alive: the turn, background tasks, or nothing
    /// (then when the idle timeout closes it).
    private func processCard(_ s: SessionSummary) -> some View {
        let tasks = (s.tasks ?? []).sorted { ($0.ambient == true ? 1 : 0, $0.startedAt ?? .distantPast) < ($1.ambient == true ? 1 : 0, $1.startedAt ?? .distantPast) }
        let busy = s.busyTasks.count
        return InspectorCard(title: tr("Process"), trailing: busy > 0 ? tr("\(busy) running") : nil) {
            if s.shownState != .idle {
                InfoRow(icon: "bolt.horizontal.circle", label: tr("Turn"), value: s.statusText)
            }
            ForEach(tasks) { t in
                BackgroundTaskRow(task: t) {
                    Task {
                        do { try await conn.stopTask(s.id, task: t.id) } catch { notice = error.localizedDescription }
                    }
                }
            }
            if busy == 0 && s.shownState == .idle {
                Text(idleLine(s))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice {
                Text(notice)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { try? await conn.stop(s.id) }
            } label: {
                Label(tr("Stop Process"), systemImage: "stop.circle")
            }
            .buttonStyle(.themed(.secondary, compact: true))
            .help(busy > 0 ? tr("Ends the process and its background tasks; the session can be resumed")
                  : tr("Ends the process; the session can be resumed"))
        }
    }

    private func idleLine(_ s: SessionSummary) -> String {
        let head = tr("Idle: nothing running in the background. The process stays open so the next message starts fast.")
        guard let at = s.closesAt else { return head }
        if at <= Date() { return head + " " + tr("It closes shortly.") }
        return head + " " + tr("Closes \(Format.relativeFuture(at)) if unused.")
    }

    private func organizeCard(_ s: SessionSummary) -> some View {
        InspectorCard(title: tr("Organize")) {
            HStack(spacing: 8) {
                Label(tr("Group"), systemImage: "folder")
                    .foregroundStyle(theme.c.textMuted)
                Spacer()
                Menu {
                    let groups = org.orderedGroups(conn.id, inUse: conn.groupNames)
                    ForEach(groups, id: \.self) { g in
                        Button { setGroup(g) } label: {
                            if s.group == g { Label(g, systemImage: "checkmark") } else { Text(g) }
                        }
                    }
                    if !groups.isEmpty { Divider() }
                    Button(tr("New Group…")) {
                        groupName = ""
                        newGroup = true
                    }
                    if s.group != nil {
                        Button(tr("Remove from Group")) { setGroup("") }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(s.group ?? tr("None"))
                            .foregroundStyle(s.group == nil ? theme.c.textFaint : theme.c.tag)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.c.textFaint)
                    }
                }
                .plainMenu()
            }
            .font(theme.font(.callout))
            ToggleRow(icon: "pin", label: tr("Pinned"),
                      isOn: Binding(get: { org.isPinned(ref) }, set: { org.setPinned([ref], $0) }))
            ToggleRow(icon: "archivebox", label: tr("Archived"),
                      isOn: Binding(get: { org.isArchived(ref) }, set: { org.setArchived([ref], $0) }))
            if let notice {
                Text(notice)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func usageCard(_ s: SessionSummary) -> some View {
        InspectorCard(title: tr("Usage")) {
            InfoRow(icon: "dollarsign.circle", label: tr("Cost"), value: Format.cost(s.costUsd) ?? "—",
                    help: tr("Estimated at list price"))
            // 0 means "not counted yet" (the server hasn't loaded the log), not empty.
            InfoRow(icon: "text.bubble", label: tr("Messages"), value: s.messages > 0 ? "\(s.messages)" : "—",
                    help: s.messages > 0 ? nil : tr("Not counted until the session is opened"))
            ContextRow(context: s.context)
            InfoRow(icon: "cpu", label: tr("Model"), value: Format.modelSetting(s.model, last: s.lastModel, info: conn.info).text)
            InfoRow(icon: "gauge.with.dots.needle.50percent", label: "Effort", value: Format.effortSetting(s.effort, applied: s.appliedEffort).text)
            InfoRow(icon: "lock.shield", label: tr("Permissions"), value: Format.mode(s.permissionMode))
            InfoRow(icon: "calendar", label: tr("Created"), value: s.createdAt.formatted(Date.FormatStyle().month().day().hour().minute().locale(Format.locale)))
            InfoRow(icon: "clock", label: tr("Updated"), value: Format.relative(s.updatedAt))
        }
    }

    @ViewBuilder
    private func tasksCard(_ s: SessionSummary) -> some View {
        let children = conn.children(of: s.id).sorted { $0.updatedAt > $1.updatedAt }
        let agents = conn.subagents[s.id] ?? []
        let count = children.count + max(agents.count, s.subagentCount ?? 0)
        if count > 0 {
            InspectorCard(title: tr("Subtasks"), trailing: "\(count)") {
                ForEach(children) { c in
                    TaskRow(icon: nil, state: c.status, live: c.live, title: c.title,
                            detail: Format.relative(c.updatedAt), selected: false) {
                        nav.selection = SessionRef(server: conn.id, session: c.id)
                    }
                }
                ForEach(agents) { a in
                    TaskRow(icon: "person.2.fill", title: a.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent",
                            detail: [(a.updatedAt ?? a.startedAt).map { Format.relative($0) }, a.entries.map { tr("\($0) entries") }]
                                .compactMap { $0 }.joined(separator: " · "),
                            selected: currentAgent == a.id) {
                        nav.selection = SessionRef(server: conn.id, session: s.id, agent: a.id)
                    }
                }
                if agents.isEmpty && (s.subagentCount ?? 0) > 0 {
                    Text(conn.supportsSubagents ? tr("Loading subagents…") : tr("This server can't list subagents"))
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.c.textFaint)
                }
                if currentAgent != nil {
                    Button {
                        nav.selection = ref
                    } label: {
                        Label(tr("Back to Parent Session"), systemImage: "arrow.turn.left.up")
                    }
                    .buttonStyle(.themed(.secondary, compact: true))
                }
            }
        }
    }

    private func actionsCard(_ s: SessionSummary) -> some View {
        InspectorCard(title: tr("Actions"), initiallyOpen: false) {
            if let onRename {
                ActionRow(icon: "pencil", label: tr("Rename…"), action: onRename)
            }
            ActionRow(icon: "plus.bubble", label: tr("New Child Session…")) {
                nav.newChildSession(of: ref)
            }
            ActionRow(icon: "terminal", label: tr("Copy Resume Command")) {
                copy(s.resumeCommand)
            }
            ActionRow(icon: "stop.circle", label: tr("Stop Process"), danger: true) {
                Task { try? await conn.stop(s.id) }
            }
            .disabled(!s.live)
        }
    }

    // MARK: Actions

    private func setGroup(_ g: String) {
        notice = nil
        if !g.isEmpty { org.addGroup(conn.id, g) }
        Task {
            do { try await conn.setGroup([sessionID], g) } catch { notice = error.localizedDescription }
        }
    }
}

// MARK: - Pieces

#if os(macOS)
/// Widths that keep sidebar + transcript + info panel inside the window. The
/// split view holds the transcript at roughly 330pt and the panel at its
/// starting width, so the window minimum has to cover all three.
enum InspectorLayout {
    static let minWidth: CGFloat = 240
    static func width(_ theme: Theme) -> CGFloat { 280 * min(theme.scale, 1.1) }
    static func windowMinWidth(inspector: Bool) -> CGFloat { inspector ? 1040 : 760 }
}

extension View {
    /// Shows the session info panel on the right. Snapshot runs
    /// (BINARY_FLAT) use a plain column, since the inspector's glass backing
    /// can't be captured.
    func sessionInspector<I: View>(isPresented: Binding<Bool>, width: CGFloat, @ViewBuilder _ panel: () -> I) -> some View {
        modifier(InspectorHost(isPresented: isPresented, width: width, panel: panel()))
    }
}

private struct InspectorHost<I: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat
    let panel: I
    @Environment(\.theme) private var theme
    /// Dragged width; 0 until the divider is first moved (then the theme's width applies).
    @AppStorage("inspectorWidth") private var savedWidth = 0.0

    func body(content: Content) -> some View {
        // A plain column with a draggable divider, like the sidebar: the system
        // inspector floats in an outlined panel on recent macOS.
        HStack(spacing: 0) {
            content
            if isPresented {
                ColumnDivider(width: Binding(get: { savedWidth > 0 ? savedWidth : Double(width) }, set: { savedWidth = $0 }),
                              range: Double(InspectorLayout.minWidth)...440, side: .trailing)
                panel.frame(width: savedWidth > 0 ? savedWidth : width)
            }
        }
    }
}
#endif

struct InspectorCard<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var initiallyOpen = true
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? initiallyOpen
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open = !isOpen }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(theme.font(.callout).weight(.semibold))
                        .foregroundStyle(theme.c.heading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.c.textFaint)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(theme.font(.caption).monospacedDigit())
                            .foregroundStyle(theme.c.textFaint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 9) {
                    content()
                }
                .padding(.top, 11)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: theme.c.surface, shadow: false)
    }
}

struct InfoRow<Trailing: View>: View {
    let icon: String
    let label: String
    let value: String
    var mono = false
    var help: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: theme.size(.caption)))
                .foregroundStyle(theme.c.textFaint)
                .frame(width: 16)
            Text(label)
                .font(theme.font(.callout))
                .foregroundStyle(theme.c.textMuted)
                .fixedSize()
            Spacer(minLength: 6)
            Text(value)
                .font(mono ? theme.mono(theme.size(.callout) - 1) : theme.font(.callout))
                .foregroundStyle(theme.c.text)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(help ?? value)
            trailing()
        }
    }
}

extension InfoRow where Trailing == EmptyView {
    init(icon: String, label: String, value: String, mono: Bool = false, help: String? = nil) {
        self.init(icon: icon, label: label, value: value, mono: mono, help: help) { EmptyView() }
    }
}

private struct ToggleRow: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(label, systemImage: icon)
                .font(theme.font(.callout))
                .foregroundStyle(theme.c.textMuted)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

private struct TaskRow: View {
    var icon: String?
    var state: SessionState = .idle
    var live = false
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    IconTile(icon: icon, tint: selected ? theme.c.selectionText : theme.c.external, size: 18)
                } else {
                    StatusDot(state: state, live: live).frame(width: 18)
                }
                Text(title)
                    .font(theme.font(.callout))
                    .foregroundStyle(selected ? theme.c.selectionText : theme.c.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(theme.font(.caption))
                        .foregroundStyle(selected ? theme.c.selectionText.opacity(0.75) : theme.c.textFaint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                .fill(selected ? theme.c.selection : hover ? theme.c.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, -6)
    }
}

/// A background task: what it is, how long it has run, and a stop button.
private struct BackgroundTaskRow: View {
    let task: BackgroundTask
    let onStop: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false
    @State private var stopping = false

    private var icon: String {
        switch task.type {
        case "shell": return "terminal"
        case "subagent": return "person.2.fill"
        case "monitor": return "eye"
        case "workflow": return "flowchart"
        default: return "gearshape.2"
        }
    }

    private var kind: String {
        switch task.type {
        case "shell": return tr("Shell")
        case "subagent": return task.agentType.map { "Agent · \($0)" } ?? "Agent"
        case "monitor": return tr("Monitor")
        case "workflow": return "Workflow"
        default: return task.type
        }
    }

    var body: some View {
        let ambient = task.ambient == true
        HStack(alignment: .top, spacing: 8) {
            IconTile(icon: icon, tint: ambient ? theme.c.textFaint : theme.c.focus, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.description.isEmpty ? kind : task.description)
                    .font(theme.font(.callout))
                    .foregroundStyle(ambient ? theme.c.textMuted : theme.c.text)
                    .lineLimit(2)
                    .help(task.description)
                Text([kind, ambient ? tr("housekeeping") : nil,
                      task.startedAt.map { tr("started \(Format.relative($0))") }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(theme.font(.small))
                    .foregroundStyle(theme.c.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                stopping = true
                onStop()
            } label: {
                if stopping { ProgressView().controlSize(.mini) } else { Image(systemName: "stop.fill") }
            }
            .buttonStyle(.icon(size: 22))
            .opacity(hover || stopping ? 1 : 0.35)
            .disabled(stopping)
            .help(tr("Stop this task"))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private struct ActionRow: View {
    let icon: String
    let label: String
    var danger = false
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(theme.font(.callout))
                .foregroundStyle(danger ? theme.c.danger : theme.c.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .fill(hover && enabled ? theme.c.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .padding(.horizontal, -6)
    }
}

/// Context window use in the info panel: a full-width bar under the label.
struct ContextRow: View {
    let context: ContextUsage?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: theme.size(.caption)))
                    .foregroundStyle(theme.c.textFaint)
                    .frame(width: 16)
                Text(tr("Context")).font(theme.font(.callout)).foregroundStyle(theme.c.textMuted)
                Spacer()
                Text(context.map { "\(Int($0.percent.rounded()))%" } ?? "—")
                    .font(theme.font(.callout).monospacedDigit())
                    .foregroundStyle((context?.percent ?? 0) >= 80 ? theme.c.warning : theme.c.text)
            }
            if let c = context {
                UsageBar(percent: c.percent).padding(.leading, 24)
                Text("\(Format.tokens(c.tokens)) / \(Format.tokens(c.max))")
                    .font(theme.font(.small).monospacedDigit())
                    .foregroundStyle(theme.c.textFaint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .help(context == nil ? tr("Known after a turn run from Binary") : tr("Context window used, as of the latest turn"))
    }
}
