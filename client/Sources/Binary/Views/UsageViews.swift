import SwiftUI

/// A thin progress bar for a percentage; warning color from `warnAt`.
struct UsageBar: View {
    let percent: Double
    var warnAt: Double = 80
    var height: CGFloat = 5
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.c.border)
                Capsule().fill(percent >= warnAt ? theme.c.warning : theme.c.focus)
                    .frame(width: max(height, g.size.width * min(max(percent, 0), 100) / 100))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(percent.rounded()))%")
    }
}

/// "Week ▓▓▓░░ 60%" for one plan window.
struct PlanWindowRow: View {
    let label: String
    let window: PlanUsage.Window
    var showReset = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textMuted)
                    .frame(width: 48, alignment: .leading)
                UsageBar(percent: window.percent)
                Text("\(Int(window.percent.rounded()))%")
                    .font(theme.font(.caption).monospacedDigit())
                    .foregroundStyle(window.percent >= 80 ? theme.c.warning : theme.c.text)
                    .frame(width: 36, alignment: .trailing)
            }
            if showReset, let r = Format.planReset(window) {
                Text(r)
                    .font(theme.font(.small))
                    .foregroundStyle(theme.c.textFaint)
                    .padding(.leading, 56)
            }
        }
        .help(Format.planWindow(window))
    }
}

#if os(macOS)
/// Plan usage at the bottom of the sidebar: one server's weekly and 5-hour
/// windows, with a menu to pick the server and a popover listing them all.
struct UsageFooter: View {
    @Environment(ServerStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(\.theme) private var theme
    /// Picked in the menu; otherwise the selected session's server.
    @AppStorage("usageServer") private var pinnedServer = ""
    @State private var showAll = false

    private var withUsage: [ServerConnection] {
        store.orderedConnections.filter { $0.usage?.available == true }
    }

    private var shown: ServerConnection? {
        let list = withUsage
        if let c = list.first(where: { $0.id.uuidString == pinnedServer }) { return c }
        if let s = nav.selection, let c = list.first(where: { $0.id == s.server }) { return c }
        return list.first
    }

    var body: some View {
        if let conn = shown, let u = conn.usage {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Menu {
                        Button(tr("Follow Selected Session")) { pinnedServer = "" }
                        Divider()
                        ForEach(withUsage) { c in
                            Button { pinnedServer = c.id.uuidString } label: {
                                if c.id == conn.id { Label(c.displayName, systemImage: "checkmark") } else { Text(c.displayName) }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(conn.displayName).font(theme.font(.caption).weight(.semibold))
                            if withUsage.count > 1 { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)) }
                        }
                        .foregroundStyle(theme.c.textMuted)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(tr("Plan usage of this server's Claude account"))
                    Spacer()
                    Button { showAll = true } label: {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.c.textFaint)
                    .help(tr("All servers"))
                    .popover(isPresented: $showAll, arrowEdge: .top) { UsageDetail() }
                }
                if let w = u.window("seven_day") { PlanWindowRow(label: tr("Week"), window: w) }
                if let w = u.window("five_hour") { PlanWindowRow(label: tr("5 hours"), window: w) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.c.sidebar)
            .overlay(alignment: .top) { Rectangle().fill(theme.c.border).frame(height: 1) }
        }
    }
}
#endif

/// Every server's plan windows, with reset times.
struct UsageDetail: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.orderedConnections) { c in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(c.displayName).font(theme.font(.callout).weight(.semibold)).foregroundStyle(theme.c.text)
                        Spacer()
                        if let at = c.usage?.at, let d = ISO8601DateFormatter.withFraction.date(from: at) {
                            Text(tr("as of \(Format.relative(d))"))
                                .font(theme.font(.small)).foregroundStyle(theme.c.textFaint)
                        }
                    }
                    if let u = c.usage, u.available, !u.windows.isEmpty {
                        ForEach(u.windows, id: \.kind) { w in
                            PlanWindowRow(label: Format.planWindowName(w.kind), window: w, showReset: true)
                        }
                    } else {
                        Text(tr("No plan usage (API key, or not read yet)"))
                            .font(theme.font(.caption)).foregroundStyle(theme.c.textFaint)
                    }
                }
            }
            Button(tr("Refresh")) {
                for c in store.orderedConnections { Task { await c.refreshUsage(force: true) } }
            }
            .buttonStyle(.themed(.secondary, compact: true))
        }
        .padding(16)
        .frame(width: 340)
    }
}
