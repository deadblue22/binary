import SwiftUI

// Effort under the message box: a button that opens a slider panel, and the
// small HUD that ⌘[ / ⌘] show.

extension Theme {
    /// A level's color: cool for low, warmer and brighter toward max. Built
    /// from the palette's status colors so it follows the theme.
    func effortColor(_ level: String, in levels: [String]) -> Color {
        guard let i = levels.firstIndex(of: level) else { return c.textMuted }
        return effortColor(at: levels.count > 1 ? Double(i) / Double(levels.count - 1) : 1)
    }

    /// The same scale at a position from 0 (low) to 1 (max).
    func effortColor(at f: Double) -> Color {
        let stops = [c.running, c.running.blend(c.external, 0.5), c.external,
                     c.external.blend(c.danger, 0.5), c.warning]
        let x = max(0, min(1, f)) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return stops[i].blend(stops[i + 1], CGFloat(x - Double(i)))
    }
}

/// The effort button in the controls bar.
struct EffortButton: View {
    /// Where the popover's arrow points from: the Mac puts it below the
    /// button when there's room; a phone needs it above, over the conversation.
    #if os(macOS)
    private static let arrowEdge: Edge = .top
    #else
    private static let arrowEdge: Edge = .bottom
    #endif
    let controller: SessionController
    var showText = true
    var onCustomModel: () -> Void
    @State private var open = false

    var body: some View {
        let effort = Format.effortSetting(controller.effort, applied: controller.appliedEffort)
        Button { open.toggle() } label: {
            ControlLabel(icon: "gauge.with.dots.needle.50percent", text: effort.value, note: effort.note, showText: showText)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: Self.arrowEdge) {
            EffortPanel(controller: controller, onCustomModel: {
                open = false
                onCustomModel()
            })
            // A popover on the phone too, not a sheet over the conversation.
            .presentationCompactAdaptation(.popover)
        }
        .help(tr("Effort and model (⌘[ / ⌘] to step)"))
        .task {
            guard showText, DebugHooks.env["BINARY_EFFORT_PANEL"] == "1" else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            open = true
        }
    }
}

/// The popover: current level, the model, and the slider.
struct EffortPanel: View {
    let controller: SessionController
    var onCustomModel: () -> Void
    @Environment(\.theme) private var theme

    private var summary: SessionSummary? { controller.summary }

    var body: some View {
        let levels = controller.effortLevels
        let level = controller.effort
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 3) {
                    EffortTitle(level: level, levels: levels, applied: controller.appliedEffort, size: 26)
                    Menu {
                        ModelMenuItems(controller: controller, onCustom: onCustomModel)
                    } label: {
                        HStack(spacing: 4) {
                            Text(Format.modelSetting(summary?.model, last: summary?.lastModel, info: controller.conn.info).text)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                        }
                        .font(theme.font(.caption).weight(.medium))
                        .foregroundStyle(theme.c.textMuted)
                        .contentShape(Rectangle())
                    }
                    .plainMenu()
                    .help(tr("Model"))
                }
                .frame(maxWidth: .infinity)
                Button { controller.setEffort("", after: 0) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.icon(size: 24))
                .disabled(level.isEmpty)
                .help(tr("Back to Default (Claude Code's own setting)"))
            }
            EffortSlider(levels: levels, level: level, applied: controller.appliedEffort,
                         onDrag: { controller.previewEffort($0) },
                         onRelease: { controller.setEffort($0, after: 0) },
                         onStep: { controller.stepEffort($0) })
            HStack {
                Text(Format.effort(levels.first))
                Spacer()
                Text(Format.effort(levels.last))
            }
            .font(theme.font(.small))
            .foregroundStyle(theme.c.textFaint)
            .padding(.horizontal, 4)
            .padding(.top, -6)
            Text(footnote)
                .font(theme.font(.small))
                .foregroundStyle(theme.c.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300 * min(theme.scale, 1.25))
        // The theme's own surface: its text colors are made for it.
        .presentationBackground(theme.c.surface)
    }

    private var footnote: String {
        let level = controller.effort
        if summary?.live == true, level == "max" {
            return tr("Restarts the process before the next turn.")
        }
        if level.isEmpty {
            return controller.appliedEffort == nil
                ? tr("Uses Claude Code's own setting.")
                : tr("Claude Code's own setting, as applied on the last turn.")
        }
        return tr("⌘[ / ⌘] lower or raise it from anywhere.")
    }
}

/// The level name in its own color; for Default, "Default" dimmed and what
/// it came to, when known.
struct EffortTitle: View {
    let level: String
    let levels: [String]
    var applied: String? = nil
    var size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        let shown = level.isEmpty ? applied : level
        Group {
            if let shown {
                if level.isEmpty {
                    Text(tr("Default") + " · ").foregroundStyle(theme.c.textMuted)
                        + Text(Format.effort(shown)).foregroundStyle(theme.effortColor(shown, in: levels))
                } else {
                    Text(Format.effort(shown)).foregroundStyle(theme.effortColor(shown, in: levels))
                }
            } else {
                Text(tr("Default")).foregroundStyle(theme.c.textMuted)
            }
        }
        .font(.system(size: size * min(theme.scale, 1.3), weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(.numericText())
        .animation(.snappy(duration: 0.2), value: level)
    }
}

/// A pill slider that snaps to the levels. At Default ("") the thumb is
/// dimmed: at what Default came to (`applied`) when known, else in the middle
/// with no fill.
struct EffortSlider: View {
    let levels: [String]
    let level: String
    var applied: String? = nil
    var height: CGFloat = 30
    var onDrag: ((String) -> Void)? = nil
    var onRelease: ((String) -> Void)? = nil
    var onStep: ((Int) -> Void)? = nil
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var dragging: Int?

    private var interactive: Bool { onRelease != nil }

    /// Faint dots inside the fill: (x, y, diameter) as fractions of the track.
    private static let sparkles: [(CGFloat, CGFloat, CGFloat)] = [
        (0.05, 0.30, 2), (0.11, 0.70, 1.5), (0.17, 0.42, 2.5), (0.24, 0.25, 1.5), (0.29, 0.66, 2),
        (0.36, 0.38, 1.5), (0.42, 0.74, 2.5), (0.48, 0.30, 2), (0.55, 0.58, 1.5), (0.61, 0.28, 2.5),
        (0.67, 0.70, 2), (0.73, 0.40, 1.5), (0.80, 0.62, 2), (0.86, 0.30, 2.5), (0.93, 0.68, 1.5),
    ]

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let n = levels.count
            let thumb = h - 6
            let inset = h / 2
            let x: (Int) -> CGFloat = { i in n > 1 ? inset + (w - 2 * inset) * CGFloat(i) / CGFloat(n - 1) : w / 2 }
            let set = dragging ?? levels.firstIndex(of: level)
            let index = set ?? applied.flatMap { levels.firstIndex(of: $0) }
            let dim = set == nil
            let thumbX = index.map(x) ?? w / 2
            let f = index.map { n > 1 ? Double($0) / Double(n - 1) : 1 } ?? 0
            ZStack(alignment: .leading) {
                theme.c.surfaceAlt
                ForEach(0..<n, id: \.self) { i in
                    Circle()
                        .fill(theme.c.textFaint.opacity(0.45))
                        .frame(width: 4, height: 4)
                        .position(x: x(i), y: h / 2)
                }
                if index != nil {
                    ZStack(alignment: .topLeading) {
                        LinearGradient(colors: [theme.effortColor(at: 0), theme.effortColor(at: f)],
                                       startPoint: .leading, endPoint: .trailing)
                        ForEach(Self.sparkles.indices, id: \.self) { k in
                            let s = Self.sparkles[k]
                            Circle()
                                .fill(.white.opacity(scheme == .dark ? 0.35 : 0.5))
                                .frame(width: s.2, height: s.2)
                                .position(x: s.0 * w, y: s.1 * h)
                        }
                    }
                    .frame(width: thumbX + inset)
                    .clipShape(Capsule())
                    .opacity(dim ? 0.35 : 1)
                }
            }
            .frame(width: w, height: h)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(theme.c.border, lineWidth: 1))
            .overlay {
                // Dimmed (Default): flat and outlined, opaque so the stop
                // underneath doesn't show through.
                Circle()
                    .fill(dim ? theme.c.surface : .white)
                    .shadow(color: .black.opacity(dim ? 0.08 : 0.22), radius: 3, y: 1)
                    .frame(width: thumb, height: thumb)
                    .overlay { if dim { Circle().strokeBorder(theme.c.borderStrong, lineWidth: 1) } }
                    .position(x: thumbX, y: h / 2)
            }
            .animation(.snappy(duration: 0.18), value: thumbX)
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard interactive, n > 0 else { return }
                    let i = nearest(v.location.x, x: x, n: n)
                    if i != dragging {
                        dragging = i
                        onDrag?(levels[i])
                    }
                }
                .onEnded { _ in
                    if let i = dragging { onRelease?(levels[i]) }
                    dragging = nil
                })
        }
        .frame(height: height * min(theme.scale, 1.25))
        .accessibilityElement()
        .accessibilityLabel("Effort")
        .accessibilityValue(Format.effort(level))
        .accessibilityAdjustableAction { d in
            onStep?(d == .increment ? 1 : -1)
        }
        .focusable(interactive)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { onStep?(-1); return onStep == nil ? .ignored : .handled }
        .onKeyPress(.rightArrow) { onStep?(1); return onStep == nil ? .ignored : .handled }
    }

    private func nearest(_ px: CGFloat, x: (Int) -> CGFloat, n: Int) -> Int {
        (0..<n).min { abs(x($0) - px) < abs(x($1) - px) } ?? 0
    }
}

/// What ⌘[ / ⌘] show for a moment above the message box.
struct EffortHUD: View {
    let level: String
    let levels: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            EffortTitle(level: level, levels: levels, size: 17)
            EffortSlider(levels: levels, level: level, height: 14)
                .frame(width: 150 * min(theme.scale, 1.25))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .card(fill: theme.c.surface, stroke: theme.c.border, radius: 14, shadow: true)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
