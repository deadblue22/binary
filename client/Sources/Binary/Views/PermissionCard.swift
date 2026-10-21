import SwiftUI

/// A pending can_use_tool request. AskUserQuestion and ExitPlanMode get their
/// own forms; everything else is allow / always allow / deny.
struct PermissionCard: View {
    let req: PermissionRequest
    let controller: SessionController
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch req.toolName {
            case "AskUserQuestion":
                QuestionCard(req: req, controller: controller)
            case "ExitPlanMode":
                PlanCard(req: req, controller: controller)
            default:
                ToolPermissionCard(req: req, controller: controller)
            }
        }
        .padding(14)
        .padding(.leading, 4)
        .background(theme.c.warning.opacity(0.05))
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.c.warning).frame(width: 4)
        }
        .card(stroke: theme.c.warning.opacity(0.45))
    }
}

private struct CardHeader: View {
    let icon: String
    let title: String
    let date: Date
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            IconTile(icon: icon, tint: theme.c.warning, size: 24)
            Text(title)
                .font(theme.font(.headline))
                .foregroundStyle(theme.c.heading)
            Spacer()
            Text(date, style: .time)
                .font(theme.font(.caption))
                .foregroundStyle(theme.c.textMuted)
        }
    }
}

struct ToolPermissionCard: View {
    let req: PermissionRequest
    let controller: SessionController
    @Environment(\.theme) private var theme
    @State private var reason = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "hand.raised.fill", title: tr("\(req.displayName ?? req.toolName) wants permission"), date: req.createdAt)
            if let t = req.title ?? req.description, !t.isEmpty,
               !(req.input["file_path"]?.string?.hasSuffix("/" + t) ?? false) {
                Text(t)
                    .font(theme.font(.callout))
                    .foregroundStyle(theme.c.text)
            }
            ToolInputView(name: req.toolName, input: req.input, cwd: controller.summary?.cwd)
            if let r = req.decisionReason, !r.isEmpty {
                Text(r).font(theme.font(.caption)).foregroundStyle(theme.c.textMuted)
            }
            if let p = req.blockedPath, !p.isEmpty {
                Label(p, systemImage: "folder.badge.minus").font(theme.font(.caption)).foregroundStyle(theme.c.textMuted)
            }
            FieldAndButtons {
                ThemedField(placeholder: tr("Reason (optional, told to Claude)"), text: $reason)
                    .frame(maxWidth: 300)
            } buttons: {
                Button(tr("Deny")) { decide(PermissionDecision(behavior: "deny", message: reason.isEmpty ? nil : reason)) }
                    .buttonStyle(.themed(.secondary))
                Spacer(minLength: 0)
                if let suggestions = req.suggestions, !suggestions.isEmpty {
                    Button(tr("Always Allow")) { decide(PermissionDecision(behavior: "allow", remember: true)) }
                        .buttonStyle(.themed(.secondary))
                        .help(Suggestions.describe(suggestions))
                }
                Button(tr("Allow")) { decide(PermissionDecision(behavior: "allow")) }
                    .buttonStyle(.themed(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(tr("Allow (⌘↩)"))
            }
            .disabled(busy)
        }
    }

    private func decide(_ d: PermissionDecision) {
        busy = true
        Task {
            await controller.respond(req, d)
            busy = false
        }
    }
}

enum Suggestions {
    static func describe(_ v: JSONValue) -> String {
        let lines: [String] = (v.array ?? []).compactMap { s in
            let dest = s["destination"]?.string.map { destName($0) } ?? ""
            switch s["type"]?.string {
            case "setMode":
                return tr("Switch to “\(Format.mode(s["mode"]?.string))”\(dest)")
            case "addRules":
                let rules = (s["rules"]?.array ?? []).map { r -> String in
                    let tool = r["toolName"]?.string ?? ""
                    if let c = r["ruleContent"]?.string { return "\(tool)(\(c))" }
                    return tool
                }
                return tr("Allow \(rules.joined(separator: ", "))\(dest)")
            case "addDirectories":
                let dirs = (s["directories"]?.array ?? []).compactMap { $0.string }
                return tr("Allow access to \(dirs.joined(separator: ", "))\(dest)")
            default:
                return nil
            }
        }
        return lines.isEmpty ? tr("Apply the permission rules Claude Code suggests") : lines.joined(separator: "\n")
    }

    private static func destName(_ d: String) -> String {
        switch d {
        case "session": return tr(" (this session only)")
        case "localSettings": return tr(" (saved to .claude/settings.local.json)")
        case "projectSettings": return tr(" (saved to .claude/settings.json)")
        case "userSettings": return tr(" (saved to user settings)")
        default: return ""
        }
    }
}

struct QuestionCard: View {
    let req: PermissionRequest
    let controller: SessionController
    @Environment(\.theme) private var theme
    @State private var picks: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]
    @State private var busy = false

    private var questions: [JSONValue] { req.input["questions"]?.array ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "questionmark.bubble.fill", title: tr("Claude has a question for you"), date: req.createdAt)
            ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in
                questionView(qi, q)
            }
            HStack {
                Button(tr("Skip")) {
                    send(PermissionDecision(behavior: "deny", message: tr("The user skipped these questions; continue with your best judgment.")))
                }
                .buttonStyle(.themed(.secondary))
                Spacer()
                Button(tr("Submit")) { submit() }
                    .buttonStyle(.themed(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!complete)
            }
            .disabled(busy)
        }
    }

    @ViewBuilder
    private func questionView(_ qi: Int, _ q: JSONValue) -> some View {
        let multi = q["multiSelect"]?.bool ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let h = q["header"]?.string {
                    Chip(text: h, tint: theme.c.warning)
                }
                Text(q["question"]?.string ?? "")
                    .font(theme.font(.body).weight(.medium))
                    .foregroundStyle(theme.c.text)
            }
            ForEach(Array((q["options"]?.array ?? []).enumerated()), id: \.offset) { _, opt in
                let label = opt["label"]?.string ?? ""
                let selected = picks[qi, default: []].contains(label)
                Button {
                    var set = picks[qi, default: []]
                    if multi {
                        if selected { set.remove(label) } else { set.insert(label) }
                    } else {
                        set = selected ? [] : [label]
                        other[qi] = nil
                    }
                    picks[qi] = set
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: selected ? (multi ? "checkmark.square.fill" : "largecircle.fill.circle") : (multi ? "square" : "circle"))
                            .foregroundStyle(selected ? theme.c.focus : theme.c.textFaint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                                .font(theme.font(.callout).weight(.medium))
                                .foregroundStyle(theme.c.text)
                            if let d = opt["description"]?.string, !d.isEmpty {
                                Text(d).font(theme.font(.caption)).foregroundStyle(theme.c.textMuted)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                            .fill(selected ? theme.c.focus.opacity(0.10) : theme.c.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                            .strokeBorder(selected ? theme.c.focus.opacity(0.6) : theme.c.border)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ThemedField(placeholder: tr("Other (type your own)"), text: Binding(get: { other[qi] ?? "" }, set: { v in
                other[qi] = v
                if !multi, !v.isEmpty { picks[qi] = [] }
            }))
        }
    }

    private var complete: Bool {
        questions.indices.allSatisfy { !picks[$0, default: []].isEmpty || !(other[$0] ?? "").isEmpty }
    }

    private func submit() {
        var answers: [String: JSONValue] = [:]
        for (qi, q) in questions.enumerated() {
            let order = (q["options"]?.array ?? []).compactMap { $0["label"]?.string }
            var parts = order.filter { picks[qi, default: []].contains($0) }
            if let o = other[qi], !o.isEmpty { parts.append(o) }
            answers[q["question"]?.string ?? "\(qi)"] = .string(parts.joined(separator: ", "))
        }
        var input = req.input.object ?? [:]
        input["answers"] = .object(answers)
        send(PermissionDecision(behavior: "allow", updatedInput: .object(input)))
    }

    private func send(_ d: PermissionDecision) {
        busy = true
        Task {
            await controller.respond(req, d)
            busy = false
        }
    }
}

struct PlanCard: View {
    let req: PermissionRequest
    let controller: SessionController
    @Environment(\.theme) private var theme
    @State private var feedback = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "list.bullet.clipboard.fill", title: tr("Claude finished a plan and is waiting for approval"), date: req.createdAt)
            ScrollView {
                MarkdownView(text: req.input["plan"]?.string ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .slimScrollers()
            }
            .frame(maxHeight: 260 * min(theme.scale, 1.3))
            .card(fill: theme.c.surface, shadow: false)
            FieldAndButtons {
                ThemedField(placeholder: tr("Feedback (sent to Claude to keep planning)"), text: $feedback)
            } buttons: {
                Button(tr("Keep Planning")) {
                    decide(PermissionDecision(behavior: "deny", message: feedback.isEmpty ? tr("The user wants to keep refining the plan.") : feedback))
                }
                .buttonStyle(.themed(.secondary))
                if let s = req.suggestions, !s.isEmpty {
                    Button(tr("Approve and Accept Edits")) { decide(PermissionDecision(behavior: "allow", remember: true)) }
                        .buttonStyle(.themed(.secondary))
                        .help(Suggestions.describe(s))
                }
                Button(tr("Approve Plan")) { decide(PermissionDecision(behavior: "allow")) }
                    .buttonStyle(.themed(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .disabled(busy)
        }
    }

    private func decide(_ d: PermissionDecision) {
        busy = true
        Task {
            await controller.respond(req, d)
            busy = false
        }
    }
}
