import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Shared building blocks of Binary's visual language: buttons, cards, chips,
// icon tiles and text-field chrome. Everything reads `@Environment(\.theme)`.

// MARK: - Buttons

enum ButtonKind {
    case primary, secondary, ghost
}

struct ThemedButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        ThemedButton(configuration: configuration, kind: kind, compact: compact)
    }
}

extension ButtonStyle where Self == ThemedButtonStyle {
    static func themed(_ kind: ButtonKind = .secondary, compact: Bool = false) -> ThemedButtonStyle {
        ThemedButtonStyle(kind: kind, compact: compact)
    }
}

private struct ThemedButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: ButtonKind
    let compact: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        // Primary's controls sit on a darker 2pt base that disappears when pressed.
        let lift: CGFloat = theme.tactile && kind != .ghost ? (pressed ? 0 : 2) : 0
        configuration.label
            .font(theme.font(compact ? .caption : .callout).weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 14)
            .padding(.vertical, compact ? 3.5 : 6.5)
            .foregroundStyle(foreground)
            .background {
                ZStack {
                    if theme.tactile && kind != .ghost {
                        shape.fill(base)
                    }
                    shape.fill(fill).padding(.bottom, lift)
                }
            }
            .overlay {
                if kind == .secondary && !theme.tactile {
                    shape.strokeBorder(theme.c.border)
                }
            }
            .offset(y: theme.tactile && pressed ? 1 : 0)
            .shadow(color: kind == .ghost || pressed ? .clear : theme.c.shadow, radius: 1.5, y: 1)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.1), value: hover)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return theme.c.onAccent
        case .secondary: return theme.c.text
        case .ghost: return hover ? theme.c.text : theme.c.textMuted
        }
    }

    private var fill: Color {
        let p = configuration.isPressed
        switch kind {
        case .primary: return hover || p ? theme.c.accentHover : theme.c.accent
        case .secondary: return hover || p ? theme.c.hover : theme.c.surface
        case .ghost: return hover || p ? theme.c.hover : .clear
        }
    }

    /// The darker base of a tactile button.
    private var base: Color {
        switch kind {
        case .primary: return theme.c.accent.blend(.black, 0.28)
        default: return theme.c.borderStrong
        }
    }
}

/// A borderless icon button that highlights on hover.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, tint: tint)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let tint: Color?
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(tint ?? (hover ? theme.c.text : theme.c.textMuted))
            .frame(minWidth: size, minHeight: size)
            .background(
                RoundedRectangle(cornerRadius: theme.controlRadius - 2, style: .continuous)
                    .fill(hover || configuration.isPressed ? theme.c.hover : .clear)
            )
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static func icon(size: CGFloat = 26, tint: Color? = nil) -> IconButtonStyle { IconButtonStyle(size: size, tint: tint) }
}

// MARK: - Cards

struct CardModifier: ViewModifier {
    var fill: Color?
    var stroke: Color?
    var radius: CGFloat?
    var shadow = true
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? theme.cardRadius, style: .continuous)
        let base = content
            .background(shape.fill(fill ?? theme.c.surface))
            .clipShape(shape)
            .overlay(shape.strokeBorder(stroke ?? theme.c.border, lineWidth: 1))
        // A shadow costs an offscreen pass per card, so only add it when asked.
        if shadow {
            base.shadow(color: theme.c.shadow, radius: theme.isPrimary ? 3 : 6, y: theme.isPrimary ? 1 : 2)
        } else {
            base
        }
    }
}

extension View {
    func card(fill: Color? = nil, stroke: Color? = nil, radius: CGFloat? = nil, shadow: Bool = true) -> some View {
        modifier(CardModifier(fill: fill, stroke: stroke, radius: radius, shadow: shadow))
    }

    /// Rounded input chrome for a `.plain` text field.
    func fieldChrome(focused: Bool = false) -> some View {
        modifier(FieldChrome(focused: focused))
    }
}

struct FieldChrome: ViewModifier {
    var focused: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(theme.font(.callout))
            .foregroundStyle(theme.c.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(shape.fill(theme.c.input))
            .overlay(shape.strokeBorder(focused ? theme.c.focus : theme.c.border, lineWidth: focused ? 1.5 : 1))
    }
}

/// A themed single-line text field with its own focus ring.
struct ThemedField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        PlainField(placeholder: placeholder, text: $text, focus: $focused)
            .fieldChrome(focused: focused)
    }
}

extension Theme {
    /// Placeholder text, drawn fainter than what the user types.
    func placeholder(_ s: String) -> Text {
        Text(s).foregroundColor(c.textFaint.opacity(0.75))
    }
}

/// A single-line plain text field whose placeholder we draw ourselves, so it
/// takes the theme's faint color (AppKit ignores the prompt's color here).
struct PlainField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    @Environment(\.theme) private var theme
    /// An input method is composing text the binding doesn't have yet.
    @State private var composing = false
    @State private var composingWatcher = ComposingWatcher()

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty && !composing {
                theme.placeholder(placeholder)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .accessibilityLabel(placeholder)
        }
        .onAppear { composingWatcher.install { composing = focus.wrappedValue && $0 } }
        .onDisappear { composingWatcher.remove() }
        .onChange(of: text) { _, _ in composing = focus.wrappedValue && ComposingWatcher.composing() }
        .onChange(of: focus.wrappedValue) { _, f in if !f { composing = false } }
    }
}

#if os(macOS)
extension View {
    /// ⇧↩ inserts a new line in a multi-line field while it has focus, like
    /// ⌥↩; plain ↩ still submits.
    func shiftReturnNewline(when focused: Bool) -> some View {
        modifier(ShiftReturnNewline(focused: focused))
    }
}

private struct ShiftReturnNewline: ViewModifier {
    let focused: Bool
    @State private var keys = NewlineKeys()

    func body(content: Content) -> some View {
        content
            .onAppear { keys.install() }
            .onDisappear { keys.remove() }
            .onChange(of: focused, initial: true) { _, f in keys.active = f }
    }
}

/// Turns ⇧↩ into the field editor's "insert newline" (what ⌥↩ does). While an
/// input method is composing, the key is left alone so ↩ confirms the candidate.
final class NewlineKeys {
    var active = false
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active, Self.isShiftReturn(event),
                  let editor = event.window?.firstResponder as? NSTextView,
                  !editor.hasMarkedText() else { return event }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { remove() }

    static func isShiftReturn(_ event: NSEvent) -> Bool {
        // 36: Return, 76: keypad Enter.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        return (event.keyCode == 36 || event.keyCode == 76) && mods == .shift
    }
}
#else
extension View {
    /// iOS: Return already inserts a new line in a multi-line field.
    func shiftReturnNewline(when focused: Bool) -> some View { self }
}
#endif

// MARK: - Layout

extension View {
    /// Lays the view out at exactly the space it is offered. Content that
    /// can't shrink further is clipped here instead of making the split view
    /// (and the whole window) wider than the screen.
    func fillAvailable() -> some View {
        GeometryReader { g in
            self.frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// A text field followed by buttons on one line; when that doesn't fit, the
/// field goes above the buttons, and then the buttons stack.
struct FieldAndButtons<Field: View, Buttons: View>: View {
    var fieldMinWidth: CGFloat = 180
    @ViewBuilder let field: () -> Field
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                field().frame(minWidth: fieldMinWidth)
                buttons()
            }
            VStack(alignment: .leading, spacing: 8) {
                field()
                HStack(spacing: 8) { buttons() }
            }
            VStack(alignment: .leading, spacing: 8) {
                field()
                VStack(alignment: .leading, spacing: 6) { buttons() }
            }
        }
    }
}

// MARK: - Small pieces

/// Small capsule label.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(theme.font(.caption).weight(.medium))
        .foregroundStyle(tint ?? theme.c.textMuted)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill((tint ?? theme.c.textFaint).opacity(0.14)))
    }
}

/// A count badge, e.g. pending approvals.
struct CountBadge: View {
    let count: Int
    var tint: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        Text("\(count)")
            .font(theme.font(.small).weight(.semibold).monospacedDigit())
            .foregroundStyle(tint == nil ? theme.c.textMuted : Color.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(tint ?? theme.c.hover))
    }
}

/// An SF Symbol on a tinted rounded square.
struct IconTile: View {
    let icon: String
    var tint: Color
    var size: CGFloat = 22
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(0.13)))
    }
}

/// A rotating disclosure chevron.
struct Chevron: View {
    let expanded: Bool
    var color: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: max(9, theme.size(.small) - 1), weight: .semibold))
            .foregroundStyle(color ?? theme.c.textFaint)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

extension Color {
    func blend(_ other: Color, _ f: CGFloat) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            var a = NSColor.clear, b = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
                b = NSColor(other).usingColorSpace(.sRGB) ?? .gray
            }
            return a.blended(withFraction: f, of: b) ?? a
        })
        #else
        Color(uiColor: UIColor { traits in
            var x: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), y = x
            UIColor(self).resolvedColor(with: traits).getRed(&x.0, green: &x.1, blue: &x.2, alpha: &x.3)
            UIColor(other).resolvedColor(with: traits).getRed(&y.0, green: &y.1, blue: &y.2, alpha: &y.3)
            return UIColor(red: x.0 + (y.0 - x.0) * f, green: x.1 + (y.1 - x.1) * f,
                           blue: x.2 + (y.2 - x.2) * f, alpha: x.3 + (y.3 - x.3) * f)
        })
        #endif
    }
}

// MARK: - Scrollers

#if os(macOS)
extension View {
    /// Put inside a ScrollView's content: makes that scroll view use slim,
    /// auto-hiding overlay scrollers even when macOS would show the wide
    /// legacy ones (a mouse is attached or "Show scroll bars: Always").
    func slimScrollers() -> some View {
        modifier(SlimScrollersModifier())
    }
}

private struct SlimScrollersModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(SlimScrollers())
    }
}

private struct SlimScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerFixView { ScrollerFixView() }
    func updateNSView(_ view: ScrollerFixView, context: Context) { view.apply() }
}

final class ScrollerFixView: NSView {
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        if observer == nil {
            // AppKit resets the style when the system preference changes.
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.apply() }
            }
        }
    }

    func apply() {
        guard let scroll = enclosingScrollView else { return }
        scroll.autohidesScrollers = true
        guard scroll.scrollerStyle != .overlay else { return }
        scroll.scrollerStyle = .overlay
        // SwiftUI sized the content for the wide scroller and only measures
        // again when the scroll view's size changes, so nudge it.
        DispatchQueue.main.async { [weak scroll] in
            guard let scroll else { return }
            let size = scroll.frame.size
            scroll.setFrameSize(NSSize(width: size.width - 1, height: size.height))
            scroll.setFrameSize(size)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Whether the focused text field has input-method text being composed. A
/// SwiftUI binding only sees text once it is committed, so a placeholder keyed
/// on the binding stays visible over composing text without this.
@MainActor
final class ComposingWatcher {
    private var monitor: Any?

    func install(_ update: @escaping (Bool) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // After the key is handled, the marked text reflects it.
            DispatchQueue.main.async { update(Self.composing(in: event.window)) }
            return event
        }
    }

    static func composing(in window: NSWindow? = nil) -> Bool {
        ((window ?? NSApp.keyWindow)?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#else
extension View {
    /// iOS scroll indicators are slim and auto-hiding already.
    func slimScrollers() -> some View { self }
}

/// iOS: a text field's binding already holds the text being composed, so
/// there is nothing to watch.
@MainActor
final class ComposingWatcher {
    func install(_ update: @escaping (Bool) -> Void) {}
    static func composing() -> Bool { false }
    func remove() {}
}
#endif
