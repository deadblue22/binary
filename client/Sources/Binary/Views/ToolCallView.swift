import SwiftUI

/// A tool_use block together with its result, collapsed to one line by default.
struct ToolCallView: View {
    let use: Block
    let result: Block?
    let busy: Bool
    let cwd: String?
    @Environment(\.theme) private var theme
    @Environment(\.subagentOpener) private var opener
    @State private var expanded = DebugHooks.expandTools
    @State private var hover = false

    private var name: String { use.name ?? tr("Tool") }
    private var input: JSONValue { use.input ?? .object([:]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                if expanded || name == "TodoWrite" { header } else { compactLine }
            }
            .buttonStyle(.plain)
            .background(hover && !expanded ? RoundedRectangle(cornerRadius: 6).fill(theme.c.hover.opacity(0.6)) : nil)
            .onHover { hover = $0 }

            if expanded {
                Rectangle().fill(theme.c.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    if let ref = subagentRef {
                        Button {
                            opener?.open(ref)
                        } label: {
                            Label(tr("Open Subagent Conversation"), systemImage: "person.2")
                        }
                        .buttonStyle(.themed(.secondary, compact: true))
                    }
                    ToolDetail(name: name, input: input, result: result, cwd: cwd)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.c.surfaceAlt.opacity(0.55))
            } else if name == "TodoWrite" {
                Rectangle().fill(theme.c.border).frame(height: 1)
                TodoList(input: input).padding(12)
            }
        }
        .modifier(ToolChrome(card: expanded || name == "TodoWrite", error: result?.isError == true))
    }

    private var header: some View {
        HStack(spacing: 9) {
            IconTile(icon: ToolInfo.icon(name), tint: ToolInfo.tint(name, theme), size: 22 * min(theme.scale, 1.25))
            Text(ToolInfo.title(name))
                .font(theme.font(.callout).weight(.semibold))
                .foregroundStyle(theme.c.text)
            Text(ToolInfo.summary(name, input, cwd: cwd))
                .font(ToolInfo.monoSummary(name) ? theme.mono(theme.size(.callout) - 0.5) : theme.font(.callout))
                .foregroundStyle(theme.c.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            status
            Chevron(expanded: expanded)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    /// Collapsed: one quiet line, so the text around it reads as the conversation.
    private var compactLine: some View {
        HStack(spacing: 6) {
            Image(systemName: ToolInfo.icon(name))
                .font(.system(size: theme.size(.caption) - 1))
                .foregroundStyle(ToolInfo.tint(name, theme).opacity(0.8))
                .frame(width: 14)
            Text(ToolInfo.title(name))
                .font(theme.font(.caption).weight(.medium))
                .foregroundStyle(theme.c.textMuted)
            Text(ToolInfo.summary(name, input, cwd: cwd))
                .font(ToolInfo.monoSummary(name) ? theme.mono(theme.size(.caption) - 0.5) : theme.font(.caption))
                .foregroundStyle(theme.c.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            status.font(.system(size: theme.size(.caption) - 1))
            Chevron(expanded: false).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var subagentRef: SessionRef? {
        guard name == "Task" || name == "Agent", let opener else { return nil }
        return opener.find(input["description"]?.string ?? "", input["prompt"]?.string ?? "")
    }

    @ViewBuilder
    private var status: some View {
        if let result {
            if result.isError == true {
                Image(systemName: "xmark.circle.fill").foregroundStyle(theme.c.danger)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.c.success.opacity(0.85))
            }
        } else if busy {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(theme.c.textFaint)
        }
    }
}

/// Lets tool cards for Task/Agent calls jump to the matching subagent.
struct SubagentOpener {
    var find: (_ description: String, _ prompt: String) -> SessionRef?
    var open: (SessionRef) -> Void
}

private struct SubagentOpenerKey: EnvironmentKey {
    static let defaultValue: SubagentOpener? = nil
}

extension EnvironmentValues {
    var subagentOpener: SubagentOpener? {
        get { self[SubagentOpenerKey.self] }
        set { self[SubagentOpenerKey.self] = newValue }
    }
}

enum ToolInfo {
    static func icon(_ name: String) -> String {
        switch name {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "square.and.pencil"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil.line"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "WebFetch": return "globe"
        case "WebSearch": return "network"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        case "Skill": return "wand.and.stars"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode", "EnterPlanMode": return "list.bullet.clipboard"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    static func tint(_ name: String, _ theme: Theme) -> Color {
        switch name {
        case "Bash", "BashOutput", "KillShell": return theme.c.focus
        case "Read", "Grep", "Glob": return theme.c.running
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return theme.c.success
        case "WebFetch", "WebSearch", "Task", "Agent": return theme.c.external
        case "TodoWrite", "ExitPlanMode", "EnterPlanMode", "AskUserQuestion": return theme.c.warning
        default: return theme.c.textMuted
        }
    }

    /// Summaries that are paths, commands or patterns read better in mono.
    static func monoSummary(_ name: String) -> Bool {
        ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Grep", "Glob"].contains(name)
    }

    static func title(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            // mcp__<server>__<tool>: show the tool part.
            return name.components(separatedBy: "__").last.flatMap { $0.isEmpty ? nil : $0 } ?? name
        }
        return name
    }

    static func summary(_ name: String, _ input: JSONValue, cwd: String?) -> String {
        func s(_ k: String) -> String? { input[k]?.string }
        switch name {
        case "Bash": return s("description") ?? s("command") ?? ""
        case "Read", "Write", "Edit", "MultiEdit":
            return s("file_path").map { Format.path($0, cwd: cwd) } ?? ""
        case "NotebookEdit": return s("notebook_path").map { Format.path($0, cwd: cwd) } ?? ""
        case "Grep", "Glob": return s("pattern") ?? ""
        case "WebFetch": return s("url") ?? ""
        case "WebSearch": return s("query") ?? ""
        case "Task", "Agent": return s("description") ?? ""
        case "Skill": return s("skill") ?? ""
        case "TodoWrite":
            let n = input["todos"]?.array?.count ?? 0
            return tr("\(n) items")
        default:
            if let o = input.object {
                for k in o.keys.sorted() {
                    if let v = o[k]?.string, !v.isEmpty { return v }
                }
            }
            return ""
        }
    }
}

struct ToolDetail: View {
    let name: String
    let input: JSONValue
    let result: Block?
    let cwd: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolInputView(name: name, input: input, cwd: cwd)
            if let result {
                VStack(alignment: .leading, spacing: 5) {
                    DetailLabel(text: result.isError == true ? tr("Error") : tr("Result"), tint: result.isError == true ? theme.c.danger : nil)
                    MonoBox(text: (result.text ?? "") + (result.truncated == true ? tr("\n… (truncated)") : ""),
                            maxHeight: 320, tint: result.isError == true ? theme.c.danger : nil)
                }
            }
        }
    }
}

/// Renders a tool's input in the most readable form we know for it.
struct ToolInputView: View {
    let name: String
    let input: JSONValue
    let cwd: String?
    @Environment(\.theme) private var theme

    var body: some View {
        switch name {
        case "Bash":
            MonoBox(text: "$ " + (input["command"]?.string ?? ""), maxHeight: 200)
        case "Edit":
            VStack(alignment: .leading, spacing: 4) {
                path
                DiffView(old: input["old_string"]?.string ?? "", new: input["new_string"]?.string ?? "")
            }
        case "MultiEdit":
            VStack(alignment: .leading, spacing: 4) {
                path
                ForEach(Array((input["edits"]?.array ?? []).enumerated()), id: \.offset) { _, e in
                    DiffView(old: e["old_string"]?.string ?? "", new: e["new_string"]?.string ?? "")
                }
            }
        case "Write":
            VStack(alignment: .leading, spacing: 4) {
                path
                MonoBox(text: input["content"]?.string ?? "", maxHeight: 240, tint: theme.c.success)
            }
        case "Read":
            path
        case "TodoWrite":
            TodoList(input: input)
        case "Task", "Agent":
            VStack(alignment: .leading, spacing: 4) {
                if let t = input["subagent_type"]?.string { DetailLabel(text: tr("Subagent: \(t)")) }
                MarkdownView(text: input["prompt"]?.string ?? "", role: .callout)
            }
        case "ExitPlanMode":
            MarkdownView(text: input["plan"]?.string ?? "")
        default:
            MonoBox(text: input.pretty, maxHeight: 200)
        }
    }

    private var path: some View {
        Label(input["file_path"]?.string.map { Format.path($0, cwd: cwd) } ?? "", systemImage: "doc")
            .font(theme.mono(theme.size(.caption)))
            .foregroundStyle(theme.c.textMuted)
            .textSelection(.enabled)
    }
}

struct DiffView: View {
    let old: String
    let new: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !old.isEmpty {
                MonoBox(text: prefixed(old, "- "), maxHeight: 180, tint: theme.c.danger)
            }
            MonoBox(text: prefixed(new, "+ "), maxHeight: 180, tint: theme.c.success)
        }
    }

    private func prefixed(_ s: String, _ p: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { p + $0 }.joined(separator: "\n")
    }
}

struct TodoList: View {
    let input: JSONValue
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array((input["todos"]?.array ?? []).enumerated()), id: \.offset) { _, t in
                let status = t["status"]?.string ?? "pending"
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: status == "completed" ? "checkmark.circle.fill" : status == "in_progress" ? "circle.inset.filled" : "circle")
                        .foregroundStyle(status == "completed" ? theme.c.success : status == "in_progress" ? theme.c.running : theme.c.textFaint)
                    Text(status == "in_progress" ? (t["activeForm"]?.string ?? t["content"]?.string ?? "") : (t["content"]?.string ?? ""))
                        .strikethrough(status == "completed", color: theme.c.textFaint)
                        .foregroundStyle(status == "completed" ? theme.c.textMuted : theme.c.text)
                        .fontWeight(status == "in_progress" ? .medium : .regular)
                }
                .font(theme.font(.callout))
            }
        }
    }
}

struct DetailLabel: View {
    let text: String
    var tint: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(.small).weight(.semibold))
            .foregroundStyle(tint ?? theme.c.textFaint)
            .textCase(.uppercase)
    }
}

/// The card around a tool call only once it is opened (or shows a list).
private struct ToolChrome: ViewModifier {
    let card: Bool
    let error: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if card {
            content.card(stroke: error ? theme.c.danger.opacity(0.45) : nil, shadow: false)
        } else {
            content
        }
    }
}
