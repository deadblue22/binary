import SwiftUI

enum Format {
    static func relative(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 946_684_800 else { return "" }
        let s = Date().timeIntervalSince(date)
        if s < 45 { return tr("just now") }
        if s < 3600 { return tr("\(max(1, Int(s / 60))) min ago") }
        if s < 86400 { return tr("\(Int(s / 3600)) h ago") }
        if s < 86400 * 7 { return tr("\(Int(s / 86400)) d ago") }
        return date.formatted(Date.FormatStyle().month().day().locale(locale))
    }

    /// "in 12 min".
    static func relativeFuture(_ date: Date) -> String {
        let s = date.timeIntervalSinceNow
        if s < 60 { return tr("in under a minute") }
        if s < 3600 { return tr("in \(Int(s / 60)) min") }
        return tr("in \(Int(s / 3600)) h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60)) min")
    }

    /// Locale for dates, following the UI language.
    static var locale: Locale { Locale(identifier: L10n.lang == .zh ? "zh_CN" : "en_US") }

    /// "14:05" for today, "Oct 18, 14:05" otherwise.
    static func clock(_ wire: String?) -> String? {
        guard let wire, let d = WireDate.parse(wire) else { return nil }
        if Calendar.current.isDateInToday(d) { return d.formatted(Date.FormatStyle().hour().minute().locale(locale)) }
        return d.formatted(Date.FormatStyle().month().day().hour().minute().locale(locale))
    }

    static func cost(_ usd: Double?) -> String? {
        guard let usd, usd > 0 else { return nil }
        return usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    /// 84k, 1.2M.
    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }

    /// "42% · 84k / 200k"
    static func context(_ c: ContextUsage) -> String {
        "\(Int(c.percent.rounded()))% · \(tokens(c.tokens)) / \(tokens(c.max))"
    }

    /// "resets 10/26" or "resets 01:39".
    static func planReset(_ w: PlanUsage.Window) -> String? {
        guard let r = w.resetsAt, let d = ISO8601DateFormatter.withFraction.date(from: r) ?? ISO8601DateFormatter().date(from: r) else { return nil }
        let when = d.timeIntervalSinceNow < 86_400
            ? d.formatted(Date.FormatStyle().hour().minute().locale(locale))
            : d.formatted(Date.FormatStyle().month(.defaultDigits).day().hour().minute().locale(locale))
        return tr("resets \(when)")
    }

    static func planWindowName(_ kind: String) -> String {
        switch kind {
        case "five_hour": return tr("5 hours")
        case "seven_day": return tr("Week")
        case "seven_day_opus": return tr("Week · Opus")
        case "seven_day_sonnet": return tr("Week · Sonnet")
        case "seven_day_oauth_apps": return tr("Week · apps")
        default: return kind
        }
    }

    /// "60% · resets Oct 26" from a usage window.
    static func planWindow(_ w: PlanUsage.Window) -> String {
        let pct = "\(Int(w.percent.rounded()))%"
        guard let r = w.resetsAt, let d = ISO8601DateFormatter.withFraction.date(from: r) ?? ISO8601DateFormatter().date(from: r) else { return pct }
        // Short enough to keep the percentage in view: a time within a day, else a date.
        let when = d.timeIntervalSinceNow < 86_400
            ? d.formatted(Date.FormatStyle().hour().minute().locale(locale))
            : d.formatted(Date.FormatStyle().month(.defaultDigits).day().locale(locale))
        return pct + " · " + tr("resets \(when)")
    }

    static func duration(_ ms: Int64?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let s = Double(ms) / 1000
        if s < 60 { return String(format: "%.1fs", s) }
        return "\(Int(s) / 60)m\(Int(s) % 60)s"
    }

    /// Shortens a path under the session cwd or the home directory.
    static func path(_ p: String, cwd: String?) -> String {
        if let cwd, !cwd.isEmpty, p.hasPrefix(cwd + "/") {
            return String(p.dropFirst(cwd.count + 1))
        }
        let home = NSHomeDirectory()
        if p.hasPrefix(home + "/") { return "~/" + p.dropFirst(home.count + 1) }
        return p
    }

    /// Human label for a model value, using the server's model list.
    static func model(_ value: String?, info: ServerInfo?) -> String {
        guard let value, !value.isEmpty else { return tr("Default") }
        if value == "default" { return tr("Default") }
        if let m = info?.models.first(where: { $0.value == value }) { return m.displayName }
        if let m = info?.models.first(where: { $0.resolvedModel == value && $0.value != "default" }) { return m.displayName }
        return value.replacingOccurrences(of: "claude-", with: "")
    }

    static let effortNames: [String: String] = [
        "low": "Low", "medium": "Medium", "high": "High", "xhigh": "XHigh", "max": "Max",
    ]

    static func effort(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return tr("Default") }
        return effortNames[value] ?? value
    }

    /// A model or effort setting for display. For Default it says what that
    /// came to on the last turn when known: note "Default", value "Medium".
    struct Setting {
        var note: String?
        var value: String
        var text: String { note.map { "\($0) · \(value)" } ?? value }
    }

    static func effortSetting(_ effort: String?, applied: String?) -> Setting {
        if let effort, !effort.isEmpty { return Setting(value: self.effort(effort)) }
        if let applied, !applied.isEmpty { return Setting(note: tr("Default"), value: self.effort(applied)) }
        return Setting(value: tr("Default"))
    }

    static func modelSetting(_ model: String?, last: String?, info: ServerInfo?) -> Setting {
        if let model, !model.isEmpty, model != "default" { return Setting(value: self.model(model, info: info)) }
        if let last, !last.isEmpty { return Setting(note: tr("Default"), value: self.model(last, info: info)) }
        return Setting(value: tr("Default"))
    }

    static let modeKeys = ["default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]

    static func modeName(_ value: String) -> String? {
        switch value {
        case "default": return tr("Ask every time")
        case "acceptEdits": return tr("Accept edits")
        case "plan": return tr("Plan mode")
        case "auto": return tr("Auto-approve (classifier)")
        case "dontAsk": return tr("Don't ask (deny unless allowed)")
        case "bypassPermissions": return tr("Bypass permissions")
        default: return nil
        }
    }

    static func mode(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return tr("Default") }
        return modeName(value) ?? value
    }
}

extension SessionState {
    func color(_ theme: Theme) -> Color {
        switch self {
        case .idle: return theme.c.textFaint
        case .starting, .running: return theme.c.running
        case .waiting: return theme.c.warning
        case .error: return theme.c.danger
        case .external: return theme.c.external
        }
    }
}

/// Says only whether you can talk to the session now: working (pulse),
/// needs you (orange), idle. Pass `SessionSummary.shownState`, so a session
/// another program has open looks idle unless a turn runs there (purple).
struct StatusDot: View {
    let state: SessionState
    let live: Bool
    @Environment(\.theme) private var theme

    private var active: Bool { state == .running || state == .starting || state == .external }

    var body: some View {
        ZStack {
            if active {
                PulseRing(color: fill)
            }
            Circle()
                .fill(fill)
                .frame(width: 8, height: 8)
            if state == .idle && !live {
                Circle().strokeBorder(theme.c.textFaint.opacity(0.6), lineWidth: 1).frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
        .help(helpText)
    }

    private var helpText: String {
        state.label + (state == .idle && live ? tr(" · process running") : "")
    }

    private var fill: Color {
        if state == .idle { return live ? theme.c.success : .clear }
        return state.color(theme)
    }
}

/// The expanding ring around a running dot. The repeating animation is
/// attached to this view only: started with withAnimation it leaked into
/// every other change in the same update (the message box and freshly shown
/// rows froze mid-animation until a scroll redrew them).
private struct PulseRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.5), lineWidth: 1.5)
            .frame(width: 8, height: 8)
            .scaleEffect(expanded ? 2.1 : 1)
            .opacity(expanded ? 0 : 1)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: expanded)
            .onAppear {
                // Next runloop turn, outside the transaction that inserted the row.
                DispatchQueue.main.async { expanded = true }
            }
    }
}

struct StatusPill: View {
    let state: SessionState
    let live: Bool
    /// The program a turn is running in, named in the pill.
    var hold: ExternalHold? = nil
    @Environment(\.theme) private var theme

    private var label: String {
        if state == .external, let h = hold {
            return tr("Working in \(h.shortName)")
        }
        return state == .idle && live ? tr("Idle · process running") : state.label
    }

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(state: state, live: live)
            Text(label)
        }
        .font(theme.font(.caption).weight(.medium))
        .foregroundStyle(state == .idle ? theme.c.textMuted : state.color(theme))
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill((state == .idle ? theme.c.textFaint : state.color(theme)).opacity(0.13)))
    }
}

/// Monospaced, selectable, scrollable text box.
struct MonoBox: View {
    let text: String
    var maxHeight: CGFloat = 260
    var tint: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius - 2, style: .continuous)
        ScrollView(.vertical) {
            Text(text.isEmpty ? " " : text)
                .font(theme.font(.monoSmall))
                .lineSpacing(theme.monoLineSpacing)
                .foregroundStyle(theme.c.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .slimScrollers()
        }
        .frame(maxHeight: maxHeight * theme.scale)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(tint?.opacity(0.10) ?? theme.c.code))
        .overlay(shape.strokeBorder(tint?.opacity(0.25) ?? theme.c.border.opacity(0.7)))
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
