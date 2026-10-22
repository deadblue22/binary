import SwiftUI

struct TranscriptView<Source: TranscriptSource>: View {
    let source: Source
    @Environment(\.theme) private var theme
    @State private var atBottom = true
    /// Last seen position of the transcript's end within its content.
    @State private var contentEnd: CGFloat = 0
    /// Height of the visible area when the end was last seen.
    @State private var viewport: CGFloat = 0
    /// The reader is dragging or flicking the transcript (where the system says so).
    @State private var userScrolling = false
    /// Rows rendered, counted from the end. Opening a session at the bottom
    /// makes the list lay out every row above, so start with the latest few.
    @State private var window = TranscriptWindow.initial

    private var rowGap: CGFloat { 16 * min(theme.scale, 1.2) }

    /// Space above a row: tight between quiet rows (tools, thinking), normal around text.
    private func gap(_ prev: TranscriptItem, _ cur: TranscriptItem) -> CGFloat {
        isQuiet(prev) && isQuiet(cur) ? 2 : rowGap
    }

    @ViewBuilder
    private func rowsView(_ rows: [TranscriptItem], busy: Bool) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
            TranscriptRow(item: item, busy: busy, cwd: source.cwd)
                .padding(.top, i == 0 ? 0 : gap(rows[i - 1], item))
                .id(item.id)
        }
    }

    var body: some View {
        let busy = source.transcriptBusy
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain stack: only the latest rows are rendered (TranscriptWindow),
                    // and exact heights keep "scrolled to the bottom" true. A lazy
                    // stack guessed the height of unbuilt rows, overshot on sessions
                    // with long messages and showed blank space until a scroll.
                    VStack(alignment: .leading, spacing: 0) {
                        let shown = source.items.suffix(window)
                        if source.items.count > window || source.hasMore {
                            Button {
                                let anchor = shown.first?.id
                                // Everything loaded is shown: fetch older entries too.
                                let fetch = source.items.count <= window
                                window += TranscriptWindow.step
                                if fetch { Task { await source.loadOlder() } }
                                // Keep the row that was first in view where it was.
                                if let anchor {
                                    DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            } label: {
                                if source.loadingOlder {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label(tr("Load earlier messages"), systemImage: "arrow.up.circle")
                                }
                            }
                            .buttonStyle(.themed(.ghost, compact: true))
                            .frame(maxWidth: .infinity)
                        }
                        if source.items.isEmpty && source.partial == nil && !busy {
                            VStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 28))
                                Text(tr("No messages yet"))
                            }
                            .font(theme.font(.callout))
                            .foregroundStyle(theme.c.textFaint)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                        rowsView(Array(shown), busy: busy)
                        if let p = source.partial {
                            PartialView(partial: p)
                                .padding(.top, rowGap)
                                .id("partial")
                        } else if busy, let text = source.activityText {
                            ActivityRow(text: text, waiting: source.waitingForApproval)
                                .padding(.top, rowGap)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .onAppear { DebugHooks.mark("bottom visible") }
                            // Where the end of the transcript is: relative to the visible
                            // area, and within the content (which grows as rows arrive).
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomMarker.self, value: BottomMarker.Value(
                                    inView: g.frame(in: .named("transcriptViewport")).minY,
                                    inContent: g.frame(in: .named("transcriptContent")).minY))
                            })
                    }
                    .coordinateSpace(name: "transcriptContent")
                    .padding(.horizontal, theme.gutter)
                    .padding(.vertical, 22)
                    .frame(maxWidth: theme.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // Short transcripts fill the view, pinned to the bottom like a chat.
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                    .slimScrollers()
                }
                .coordinateSpace(name: "transcriptViewport")
                .scrollDismissesKeyboard(.interactively)
                .modifier(ScrollPhaseWatcher(userScrolling: $userScrolling))
                // Start at the bottom; following new content is up to atBottom below.
                .modifier(InitialAnchor(top: DebugHooks.scrollTop))
                .background(theme.c.background)
                // Follow new content only while the end is in view. Content that
                // grew moves the end down without the reader scrolling away, and
                // so does a smaller view (the keyboard, an approval card below),
                // so only a change with the same sizes counts as scrolling.
                .onPreferenceChange(BottomMarker.self) { v in
                    let grew = v.inContent != contentEnd
                    let resized = geo.size.height != viewport
                    contentEnd = v.inContent
                    viewport = geo.size.height
                    let visible = v.inView <= geo.size.height + 40
                    if visible {
                        atBottom = true
                    } else if userScrolling {
                        atBottom = false
                    } else if resized || (!grew && ScrollPhaseWatcher.available) {
                        // The view changed size (the keyboard, an approval card) or
                        // moved without the reader (a push settling, a card sliding
                        // in): still following, so keep the end in view.
                        if atBottom { DispatchQueue.main.async { scrollToBottom(proxy) } }
                    } else if !grew {
                        atBottom = false
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button { atBottom = true; scrollToBottom(proxy) } label: {
                            Label(tr("Latest"), systemImage: "arrow.down")
                        }
                        .buttonStyle(.themed(.secondary, compact: true))
                        .padding(14)
                        .transition(.opacity)
                    }
                }
                .onAppear { if !DebugHooks.scrollTop { scrollToBottom(proxy, delayed: true) } }
                .onChange(of: source.items.count) { _, _ in
                    if atBottom { scrollToBottom(proxy) }
                }
                .onChange(of: source.partial) { _, _ in
                    if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: theme) { _, _ in scrollToBottom(proxy, delayed: true) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, delayed: Bool = false) {
        if DebugHooks.scrollTop { return }
        proxy.scrollTo("bottom", anchor: .bottom)
        // Text views settle their heights after the first layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + (delayed ? 0.15 : 0.05)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

enum TranscriptWindow {
    static let initial = 60
    static let step = 150
}

/// Collapsed tool calls and thinking are one quiet line each; runs of them sit
/// close together so the text around them reads as the conversation.
private func isQuiet(_ item: TranscriptItem) -> Bool {
    switch item.kind {
    case .tool, .thinking: return true
    default: return false
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let busy: Bool
    let cwd: String?

    var body: some View {
        switch item.kind {
        case .user(let text, let images):
            UserMessageView(text: text, imageKeys: images, time: item.time)
        case .assistant(let text):
            MarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let text):
            ThinkingView(text: text)
        case .tool(let use, let result):
            ToolCallView(use: use, result: result, busy: busy, cwd: cwd)
        case .system(let subtype, let text, let isError, let event):
            SystemRow(subtype: subtype, text: text, isError: isError, event: event)
        case .result(let e):
            ResultRow(entry: e)
        }
    }
}

struct UserMessageView: View {
    let raw: String
    let imageKeys: [String?]
    var time: String? = nil
    @Environment(\.theme) private var theme
    @State private var expanded = false

    init(text: String, imageKeys: [String?] = [], time: String? = nil) {
        self.raw = text
        self.imageKeys = imageKeys
        self.time = time
    }

    private var text: String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var long: Bool { text.count > 1600 }

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !imageKeys.isEmpty {
                    // Images sit above the bubble, as in chat apps.
                    let h: CGFloat = imageKeys.count == 1 ? 240 : 150
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(imageKeys.enumerated()), id: \.offset) { _, key in
                                RemoteImageThumb(key: key, height: h)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: h)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !text.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(long && !expanded ? String(text.prefix(1600)) + "…" : text)
                            .font(theme.font(.body))
                            .lineSpacing(theme.lineSpacing * 0.8)
                            .foregroundStyle(theme.c.userText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if long {
                            Button(expanded ? tr("Collapse") : tr("Show all")) { expanded.toggle() }
                                .buttonStyle(.themed(.ghost, compact: true))
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(bubble.fill(theme.c.userBubble))
                    .overlay(bubble.strokeBorder(theme.c.userBubbleBorder))
                }
                if let t = Format.clock(time) {
                    Text(t)
                        .font(theme.font(.small))
                        .foregroundStyle(theme.c.textFaint)
                        .padding(.trailing, 6)
                }
            }
        }
        .padding(.top, 4)
    }

    private var bubble: UnevenRoundedRectangle {
        let r = theme.bubbleRadius
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                      bottomTrailingRadius: theme.isPrimary ? r : 5, topTrailingRadius: r,
                                      style: .continuous)
    }
}

struct ThinkingView: View {
    let text: String
    @Environment(\.theme) private var theme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                    Text(tr("Thinking"))
                    Chevron(expanded: expanded)
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.c.textFaint)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                // Thinking blocks often end with blank lines.
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(theme.font(.callout))
                    .lineSpacing(theme.lineSpacing * 0.8)
                    .foregroundStyle(theme.c.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(theme.c.quoteBar).frame(width: 2)
                    }
            }
        }
    }
}

struct SystemRow: View {
    let subtype: String
    let text: String
    let isError: Bool
    var event: String? = nil
    @Environment(\.theme) private var theme
    @State private var expanded = false

    var body: some View {
        if subtype == "task_notification" {
            TaskNotificationRow(text: text, isError: isError)
        } else if subtype == "app_event" {
            // Something the desktop app injected (linked-session updates,
            // messages from other sessions, CI, scheduled tasks): a quiet line.
            TaskNotificationRow(text: text, isError: isError, icon: Self.eventIcon(event), dim: true)
        } else if subtype == "compact_summary" {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.compress.vertical")
                        Text(tr("Conversation summary (continued after compaction)"))
                        Chevron(expanded: expanded)
                    }
                    .font(theme.font(.caption).weight(.medium))
                    .foregroundStyle(theme.c.textMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.c.surfaceAlt))
                }
                .buttonStyle(.plain)
                if expanded {
                    MarkdownView(text: text)
                        .padding(14)
                        .card(fill: theme.c.surfaceAlt, shadow: false)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon)
                Text(text)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 4)
                    .onTapGesture { expanded.toggle() }
            }
            .font(theme.font(.caption))
            .foregroundStyle(isError ? theme.c.danger : theme.c.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isError ? theme.c.danger.opacity(0.1) : theme.c.surfaceAlt.opacity(0.8)))
            .frame(maxWidth: .infinity, alignment: subtype == "local_command" ? .leading : .center)
        }
    }

    static func eventIcon(_ event: String?) -> String {
        switch event {
        case "side-sessions-event": return "rectangle.stack"
        case "cross-session-message": return "bubble.left.and.text.bubble.right"
        case "ci-monitor-event": return "checkmark.seal"
        case "scheduled-task": return "clock"
        default: return "app.badge"
        }
    }

    private var icon: String {
        switch subtype {
        case "compact_boundary": return "arrow.down.right.and.arrow.up.left"
        case "interrupted": return "stop.circle"
        case "local_command": return "terminal"
        case "api_error": return "exclamationmark.triangle"
        default: return "info.circle"
        }
    }
}

/// A background task or agent finishing (server: system entry with subtype
/// task_notification). One-line summary; the result opens as Markdown.
struct TaskNotificationRow: View {
    let text: String
    let isError: Bool
    var icon: String? = nil
    /// Quieter look for desktop-app events.
    var dim = false
    @Environment(\.theme) private var theme
    @State private var expanded = DebugHooks.expandTools
    @State private var hover = false

    private var parts: (summary: String, body: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: "\n\n") else {
            let first = t.split(separator: "\n", maxSplits: 1).map(String.init)
            return (first.first ?? t, first.count > 1 ? first[1] : "")
        }
        return (String(t[..<r.lowerBound]), String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        let p = parts
        let tint = isError ? theme.c.danger : (dim ? theme.c.textFaint : theme.c.success)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    IconTile(icon: isError ? "exclamationmark.octagon" : (icon ?? "bell"), tint: tint, size: 22 * min(theme.scale, 1.25))
                    Text(p.summary)
                        .font(theme.font(.callout).weight(dim ? .regular : .medium))
                        .foregroundStyle(dim ? theme.c.textMuted : theme.c.text)
                        .lineLimit(p.body.isEmpty ? 2 : 1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !p.body.isEmpty { Chevron(expanded: expanded) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!p.body.isEmpty)
            .background(hover && !expanded && !p.body.isEmpty ? theme.c.hover.opacity(0.6) : .clear)
            .onHover { hover = $0 }
            .help(p.summary)
            if expanded && !p.body.isEmpty {
                Rectangle().fill(theme.c.border).frame(height: 1)
                MarkdownView(text: p.body, role: .callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.c.surfaceAlt.opacity(0.55))
            }
        }
        .card(fill: dim ? theme.c.surfaceAlt.opacity(0.5) : nil,
              stroke: isError ? theme.c.danger.opacity(0.45) : (dim ? theme.c.border.opacity(0.6) : nil), shadow: false)
    }
}

struct ResultRow: View {
    let entry: Entry
    @Environment(\.theme) private var theme

    var body: some View {
        let parts = [Format.duration(entry.durationMs), Format.cost(entry.costUsd).map { tr("total ") + $0 }].compactMap { $0 }
        if entry.isError == true, let t = entry.text, !t.isEmpty {
            Label(t, systemImage: "xmark.octagon")
                .font(theme.font(.caption))
                .foregroundStyle(theme.c.danger)
                .textSelection(.enabled)
        } else if !parts.isEmpty {
            HStack(spacing: 8) {
                Rectangle().fill(theme.c.border).frame(height: 1)
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal")
                    Text(tr("Turn finished · ") + parts.joined(separator: " · "))
                }
                .font(theme.font(.small))
                .foregroundStyle(theme.c.textFaint)
                .fixedSize()
                Rectangle().fill(theme.c.border).frame(height: 1)
            }
        }
    }
}

struct ActivityRow: View {
    let text: String
    let waiting: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if waiting {
                Image(systemName: "hand.raised.fill").foregroundStyle(theme.c.warning)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(theme.font(.callout))
                .foregroundStyle(theme.c.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(theme.c.surfaceAlt))
    }
}

struct PartialView: View {
    let partial: Partial
    @Environment(\.theme) private var theme

    var body: some View {
        switch partial.type {
        case "text":
            MarkdownView(text: partial.text ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        case "thinking":
            VStack(alignment: .leading, spacing: 6) {
                ActivityRow(text: tr("Thinking…"), waiting: false)
                if let t = partial.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    Text(String(t.suffix(600)))
                        .font(theme.font(.callout))
                        .foregroundStyle(theme.c.textFaint)
                        .lineLimit(6)
                        .padding(.leading, 12)
                }
            }
        default:
            ActivityRow(text: tr("Preparing \(partial.name ?? tr("tool call"))") + (partial.size > 0 ? tr(" (\(partial.size) bytes)") : "…"), waiting: false)
        }
    }
}

/// The end of the transcript: its y in the visible area and in the content.
private struct BottomMarker: PreferenceKey {
    struct Value: Equatable {
        var inView: CGFloat = 0
        var inContent: CGFloat = 0
    }
    static let defaultValue = Value()
    static func reduce(value: inout Value, nextValue: () -> Value) { value = nextValue() }
}

/// Tells whether a scroll is the reader's (dragging, flicking) on iOS 18 and
/// later. The Mac goes by content and view size changes alone.
private struct ScrollPhaseWatcher: ViewModifier {
    @Binding var userScrolling: Bool

    static var available: Bool {
        #if os(iOS)
        if #available(iOS 18, *) { return true }
        #endif
        return false
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Opens at the bottom (or top) without pinning there as content grows,
/// which would pull a reader who scrolled up back down.
private struct InitialAnchor: ViewModifier {
    let top: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, iOS 18, *) {
            content.defaultScrollAnchor(top ? .top : .bottom, for: .initialOffset)
        } else {
            content.defaultScrollAnchor(top ? .top : .bottom)
        }
    }
}
