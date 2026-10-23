import SwiftUI

struct TranscriptView<Source: TranscriptSource>: View {
    let source: Source
    /// A row to scroll to once (a search match); `onJumped` is called when
    /// it was shown or can't be found.
    var jump: TranscriptJump? = nil
    var onJumped: () -> Void = {}
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
    /// Bumped when row heights change everywhere (width, theme), so chunks
    /// drawn as placeholders measure their rows again.
    @State private var measureGeneration = 0
    @State private var measuredFor: MeasureKey?
    /// Which rows' disclosures are open, kept here since rows far from view
    /// are dropped and built again.
    @State private var expansion = ExpansionStore()
    /// The row a jump landed on, marked for a moment.
    @State private var highlighted: String?
    /// Earlier rows are being added: keep the distance to the end, not to the top.
    @State private var holdingEnd = false

    private var rowGap: CGFloat { 16 * min(theme.scale, 1.2) }

    /// Space above a row: tight between quiet rows (tools, thinking), normal around text.
    private func gap(_ prev: TranscriptItem, _ cur: TranscriptItem) -> CGFloat {
        isQuiet(prev) && isQuiet(cur) ? 2 : rowGap
    }

    @ViewBuilder
    private func rowsView(_ rows: [TranscriptItem], busy: Bool, viewport: CGFloat) -> some View {
        ForEach(TranscriptChunks.split(rows)) { chunk in
            TranscriptChunk(viewport: viewport, generation: measureGeneration) {
                ForEach(chunk.range, id: \.self) { i in
                    TranscriptRow(item: rows[i], busy: busy, cwd: source.cwd)
                        .background {
                            if highlighted == rows[i].id {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(theme.c.focus.opacity(0.14))
                                    .padding(-6)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.top, i == 0 ? 0 : gap(rows[i - 1], rows[i]))
                        .id(rows[i].id)
                        .environment(\.rowExpansion, RowExpansion(store: expansion, row: rows[i].id))
                }
            }
            // Rows of a chunk drawn as empty space have no ids to scroll to; the chunk does.
            .id(TranscriptChunks.scrollID(chunk.id))
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
                            // Earlier rows load on their own as the reader nears the top.
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, rowGap)
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
                        rowsView(Array(shown), busy: busy, viewport: geo.size.height)
                        if let p = source.partial {
                            PartialView(partial: p)
                                .padding(.top, rowGap)
                                .id("partial")
                        } else if busy, let text = source.activityText {
                            ActivityRow(text: text, waiting: source.waitingForApproval)
                                .padding(.top, rowGap)
                        }
                        // The bottom margin is part of the marker, so scrolling to it
                        // lands where the view opens (at the very end); with the margin
                        // below it, every scroll to the bottom moved the rows by that much.
                        Color.clear
                            .frame(height: 23)
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
                    .padding(.top, 22)
                    .frame(maxWidth: theme.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // Short transcripts fill the view, pinned to the bottom like a chat.
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                    .background(PrependKeeper(holding: holdingEnd) { nearTop in
                        // Not while following the end: a transcript opening at the
                        // bottom passes the top before it gets there.
                        if nearTop && !atBottom { showEarlier() }
                    })
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
                .task(id: jump?.serial) {
                    guard let jump else { return }
                    await show(jump.uuid, proxy)
                    if !Task.isCancelled { onJumped() }
                }
                // Rows drawn as placeholders keep their old height through a resize;
                // measure them again once it settles.
                .task(id: MeasureKey(width: geo.size.width, theme: theme)) {
                    let key = MeasureKey(width: geo.size.width, theme: theme)
                    guard let old = measuredFor else { measuredFor = key; return }
                    guard old != key else { return }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    measuredFor = key
                    measureGeneration += 1
                }
                #if os(macOS)
                .task {
                    guard let pages = Int(DebugHooks.env["BINARY_SCROLL_BENCH"] ?? "") else { return }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    for _ in 0..<pages { await source.loadOlder() }
                    window = source.items.count
                    DebugHooks.err("bench: \(source.items.count) rows")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    DebugHooks.scrollBench()
                }
                #endif
            }
        }
    }

    /// Scrolls to the first row of entry `uuid`, loading older pages until
    /// it's there, and marks it.
    private func show(_ uuid: String, _ proxy: ScrollViewProxy) async {
        func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        // After the opening scroll to the bottom (onAppear) has run.
        await sleep(300)
        var pages = 0
        while !Task.isCancelled {
            if let i = source.items.firstIndex(where: { $0.id == uuid || $0.id.hasPrefix(uuid + "-") }) {
                let rows = source.items
                let row = rows[i].id
                window = max(window, rows.count - i + 4)
                atBottom = false
                await sleep(50)
                // Bring its chunk near, so the row is built, then center the row.
                let first = rows.count - min(window, rows.count)
                if let chunk = TranscriptChunks.split(Array(rows[first...])).first(where: { $0.range.contains(i - first) }) {
                    proxy.scrollTo(TranscriptChunks.scrollID(chunk.id), anchor: .top)
                    await sleep(80)
                }
                proxy.scrollTo(row, anchor: .center)
                withAnimation(.easeOut(duration: 0.2)) { highlighted = row }
                // Text views settle their heights after the first layout pass.
                await sleep(150)
                proxy.scrollTo(row, anchor: .center)
                await sleep(1800)
                withAnimation(.easeOut(duration: 0.6)) { if highlighted == row { highlighted = nil } }
                return
            }
            if source.loadingOlder {
                await sleep(100)
            } else if source.hasMore && pages < 40 {
                pages += 1
                await source.loadOlder()
            } else {
                return
            }
        }
    }

    /// Shows the next rows above, fetching older entries once everything
    /// loaded is shown. The view holds its distance to the end until they
    /// are laid out.
    private func showEarlier() {
        guard !holdingEnd, source.items.count > window || (source.hasMore && !source.loadingOlder) else { return }
        let fetch = source.items.count <= window
        holdingEnd = true
        window += TranscriptWindow.step
        Task {
            if fetch { await source.loadOlder() }
            // Text views settle their heights after the first layout pass.
            try? await Task.sleep(nanoseconds: 300_000_000)
            holdingEnd = false
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
    @RowExpanded private var expanded = false

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
    @RowExpanded private var expanded = false

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
    @RowExpanded private var expanded = false

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
    @RowExpanded private var expanded = DebugHooks.expandTools
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

/// Keeps the rows in view where they are while `holding` (earlier rows are
/// being added above them), and says when the reader is within a screen of
/// the top. Content added above otherwise pushed the view to its start.
/// Works on the platform scroll view: it moves the visible area in the same
/// layout pass the content grew in, so no frame shows the rows pushed down
/// (SwiftUI's scroll position can only be set a pass later).
private struct PrependKeeper: View {
    let holding: Bool
    let onScroll: (_ nearTop: Bool) -> Void

    var body: some View {
        Representable(holding: holding, onScroll: onScroll).allowsHitTesting(false)
    }

    #if os(macOS)
    private struct Representable: NSViewRepresentable {
        let holding: Bool
        let onScroll: (Bool) -> Void
        func makeNSView(context: Context) -> PrependKeeperView { PrependKeeperView() }
        func updateNSView(_ view: PrependKeeperView, context: Context) {
            view.holding = holding
            view.onScroll = onScroll
            view.attach()
        }
    }
    #else
    private struct Representable: UIViewRepresentable {
        let holding: Bool
        let onScroll: (Bool) -> Void
        func makeUIView(context: Context) -> PrependKeeperView { PrependKeeperView() }
        func updateUIView(_ view: PrependKeeperView, context: Context) {
            view.holding = holding
            view.onScroll = onScroll
            view.attach()
        }
    }
    #endif
}

#if os(macOS)
final class PrependKeeperView: NSView {
    var holding = false
    var onScroll: (Bool) -> Void = { _ in }
    private weak var doc: NSView?
    private var height: CGFloat = 0
    private var nearTop = false
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    func attach() {
        guard let scroll = enclosingScrollView, let doc = scroll.documentView, doc !== self.doc else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.doc = doc
        height = doc.frame.height
        doc.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true
        // Delivered as they happen (no queue), inside the layout pass.
        observers = [
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.resized() }
            },
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            },
        ]
    }

    private func resized() {
        guard let doc, let scroll = enclosingScrollView else { return }
        let added = doc.frame.height - height
        height = doc.frame.height
        guard holding, added > 0 else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        // Flipped (SwiftUI's): the origin counts from the top, so it moves down
        // with the rows; unflipped it counts from the bottom and already holds.
        if doc.isFlipped { origin.y += added }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func scrolled() {
        guard let doc, let clip = enclosingScrollView?.contentView else { return }
        let fromTop = doc.isFlipped ? clip.bounds.minY : doc.frame.height - clip.bounds.maxY
        let near = fromTop < clip.bounds.height
        guard near != nearTop || near else { return }
        nearTop = near
        // Not from within the layout pass that moved it.
        DispatchQueue.main.async { [onScroll] in onScroll(near) }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
#else
final class PrependKeeperView: UIView {
    var holding = false
    var onScroll: (Bool) -> Void = { _ in }
    private weak var scroll: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var nearTop = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attach()
    }

    func attach() {
        var v = superview
        while let s = v, !(s is UIScrollView) { v = s.superview }
        guard let scroll = v as? UIScrollView, scroll !== self.scroll else { return }
        self.scroll = scroll
        // Called as the values change, inside the layout pass.
        observations = [
            scroll.observe(\.contentSize, options: [.old, .new]) { [weak self] s, c in
                MainActor.assumeIsolated { self?.resized(s, from: c.oldValue?.height ?? 0, to: c.newValue?.height ?? 0) }
            },
            scroll.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
                MainActor.assumeIsolated { self?.scrolled(s) }
            },
        ]
    }

    private func resized(_ scroll: UIScrollView, from old: CGFloat, to new: CGFloat) {
        let added = new - old
        guard holding, added > 0, old > 0 else { return }
        var offset = scroll.contentOffset
        offset.y += added
        scroll.contentOffset = offset
    }

    private func scrolled(_ scroll: UIScrollView) {
        let near = scroll.contentOffset.y + scroll.adjustedContentInset.top < scroll.bounds.height
        guard near != nearTop || near else { return }
        nearTop = near
        DispatchQueue.main.async { [onScroll] in onScroll(near) }
    }
}
#endif

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


/// Groups of transcript rows. Boundaries depend only on the rows' ids, so a
/// group keeps its identity (and measured height) as rows arrive at the end
/// or older ones are loaded above.
enum TranscriptChunks {
    struct Chunk: Identifiable {
        /// The first row's id.
        var id: String
        var range: Range<Int>
    }

    /// A group starts at about one row in `average`, and is cut after `maximum`.
    static let average: UInt64 = 12
    static let maximum = 24

    static func scrollID(_ chunk: String) -> String { "chunk:" + chunk }

    static func split(_ rows: [TranscriptItem]) -> [Chunk] {
        var out: [Chunk] = []
        var start = 0
        var sinceNatural = 0
        for i in rows.indices where i > 0 {
            sinceNatural += 1
            if hash(rows[i].id) % average == 0 {
                out.append(Chunk(id: rows[start].id, range: start..<i))
                start = i
                sinceNatural = 0
            } else if sinceNatural % maximum == 0 {
                out.append(Chunk(id: rows[start].id, range: start..<i))
                start = i
            }
        }
        if start < rows.count { out.append(Chunk(id: rows[start].id, range: start..<rows.count)) }
        return out
    }

    /// FNV-1a, so boundaries don't move between launches like hashValue would.
    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

/// A group of rows that is only built near the visible area; elsewhere it is
/// empty space of the height it last measured. Scrolling costs SwiftUI work
/// for every built row (eager and lazy stacks alike), so a long transcript
/// stuttered once its history was loaded.
private struct TranscriptChunk<Content: View>: View {
    let viewport: CGFloat
    /// Changes when the measured height no longer holds (width, theme).
    let generation: Int
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat?
    @State private var near = true

    var body: some View {
        Group {
            if near || height == nil {
                VStack(alignment: .leading, spacing: 0, content: content)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            } else {
                Color.clear.frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Built within a screen of the visible area and dropped beyond two,
        // so scrolling back and forth at the edge doesn't rebuild rows.
        .onGeometryChange(for: Int.self) { p in
            let f = p.frame(in: .named("transcriptViewport"))
            let screen = max(viewport, 400)
            let distance = max(-f.maxY, f.minY - viewport, 0)
            return distance < screen ? 0 : distance < 2 * screen ? 1 : 2
        } action: { band in
            if band == 0 { near = true } else if band == 2 { near = false }
        }
        .onChange(of: generation) { _, _ in height = nil }
    }
}

private struct MeasureKey: Equatable {
    var width: CGFloat
    var theme: Theme
}

/// Open disclosures of transcript rows, by row id.
@MainActor
@Observable
final class ExpansionStore {
    var open: [String: Bool] = [:]
}

/// The disclosure state of the row a view is in.
struct RowExpansion {
    let store: ExpansionStore
    let row: String
}

extension EnvironmentValues {
    @Entry var rowExpansion: RowExpansion?
}

/// Whether a row's disclosure is open. Inside the transcript it is kept by
/// the transcript, so it survives the row being dropped and built again;
/// elsewhere (previews) by the view.
@MainActor
@propertyWrapper
struct RowExpanded: DynamicProperty {
    @Environment(\.rowExpansion) private var slot
    @State private var local: Bool
    private let initial: Bool

    init(wrappedValue: Bool) {
        _local = State(initialValue: wrappedValue)
        initial = wrappedValue
    }

    var wrappedValue: Bool {
        get { slot.map { $0.store.open[$0.row] ?? initial } ?? local }
        nonmutating set {
            if let slot { slot.store.open[slot.row] = newValue } else { local = newValue }
        }
    }
}
