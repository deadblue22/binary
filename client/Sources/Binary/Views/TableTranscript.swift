#if os(macOS)
import AppKit
import SwiftUI

// The Mac transcript is an NSTableView. Rows are views the table reuses as
// they scroll by, so scrolling moves layers without running SwiftUI, and rows
// come into view one at a time. A SwiftUI stack of the whole transcript had
// to build or drop dozens of rows at once (a stalled frame each time), and
// every row hosted in SwiftUI still costs work on each scrolled frame, so the
// collapsed tool and thinking lines that fill tool-heavy sessions are drawn
// with AppKit; everything else is the SwiftUI row it always was.

/// A row of the table: a transcript item, or one of the rows around them.
enum TableRow: Hashable {
    /// Earlier rows load on their own as the reader nears the top.
    case loading
    case empty
    case item(TranscriptItem)
    /// A message sent from here that the transcript doesn't show yet.
    case outgoing(id: UUID, text: String, sent: Bool)
    case partial(Partial)
    case activity(text: String, waiting: Bool)

    var id: String {
        switch self {
        case .loading: return "loading"
        case .empty: return "empty"
        case .item(let item): return item.id
        case .outgoing(let id, _, _): return "outgoing:" + id.uuidString
        case .partial: return "partial"
        case .activity: return "activity"
        }
    }

    var item: TranscriptItem? {
        if case .item(let item) = self { return item }
        return nil
    }
}

/// Search matches and the row marked after a jump.
struct TableMarks: Equatable {
    var query = ""
    var matches: Set<String> = []
    var selected: String?
    var flash: String?

    func search(_ id: String) -> SearchHighlight {
        SearchHighlight(query: matches.contains(id) ? query : "", selected: selected == id)
    }

    func marked(_ id: String) -> Bool { flash == id || selected == id }
}

/// What the transcript view asks of the table, and whether it shows the end.
@MainActor
@Observable
final class TableTranscriptModel {
    /// The end of the transcript is in view, so new content keeps it there.
    var atBottom = true
    @ObservationIgnored fileprivate weak var coordinator: TableTranscript.Coordinator?

    func scrollToBottom() {
        atBottom = true
        coordinator?.scrollToEnd()
    }

    /// Centers the first row of entry `uuid`; false if it isn't loaded.
    func reveal(_ uuid: String) -> Bool {
        coordinator?.reveal(uuid) ?? false
    }
}

struct TableTranscript: NSViewRepresentable {
    let rows: [TableRow]
    /// Images of the outgoing messages, by message.
    let outgoingImages: [UUID: [PlatformImage]]
    let busy: Bool
    let cwd: String?
    let marks: TableMarks
    let expansion: ExpansionStore
    let model: TableTranscriptModel
    /// The reader is within a screen of the top.
    let onNearTop: () -> Void
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TranscriptTableView()
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = TranscriptScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        let coordinator = context.coordinator
        coordinator.attach(table, model: model)
        coordinator.update(self)
        DispatchQueue.main.async { coordinator.scrollToEnd() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    // Fills what it is offered; asking AppKit for a fitting size walked every row.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private weak var table: NSTableView?
        private weak var model: TableTranscriptModel?
        private var rows: [Shown] = []
        private var images: [UUID: [PlatformImage]] = [:]
        private var busy = false
        private var cwd: String?
        private var marks = TableMarks()
        private var environment = EnvironmentValues()
        private var expansion = ExpansionStore()
        private var onNearTop: () -> Void = {}
        private var theme: Theme?
        private var width: CGFloat = 0
        /// Measured heights of SwiftUI rows, with what they were measured for.
        private var heights: [String: (key: Int, height: CGFloat)] = [:]
        /// Rows whose measured height differs from what the table has.
        private var pending = IndexSet()
        /// Disclosure state the rows were last laid out with.
        private var shownOpen: [String: Bool] = [:]
        private var observers: [NSObjectProtocol] = []
        private var nearTop = false
        /// A SwiftUI row laid out off screen to measure heights.
        private lazy var sizer = HostedRowCell()

        /// A row with the space around it, as laid out.
        struct Shown: Hashable {
            var row: TableRow
            var top: CGFloat
            var bottom: CGFloat
        }

        func attach(_ table: NSTableView, model: TableTranscriptModel) {
            self.table = table
            self.model = model
            model.coordinator = self
            if DebugHooks.scrollTop { model.atBottom = false }
            table.dataSource = self
            table.delegate = self
            guard let clip = table.enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            observers = [
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                },
                // A shorter or taller view (the composer, an approval card) keeps the end in view.
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.model?.atBottom == true { self?.scrollToEnd() } }
                },
            ]
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func update(_ view: TableTranscript) {
            guard let table else { return }
            environment = view.environment
            onNearTop = view.onNearTop
            images = view.outgoingImages
            if expansion !== view.expansion {
                expansion = view.expansion
                watchExpansion()
            }
            let restyle = theme != environment.theme
            theme = environment.theme
            let reconfigure = busy != view.busy || cwd != view.cwd || marks != view.marks
            busy = view.busy
            cwd = view.cwd
            marks = view.marks

            let next = layout(view.rows)
            if restyle {
                heights.removeAll()
                keepingPlace {
                    rows = next
                    table.reloadData()
                }
                return
            }
            if next != rows { apply(next) }
            if reconfigure { reloadVisible() }
            // All rows fit: nothing to scroll toward the top, so fetch the earlier ones now.
            if rows.first?.row == .loading, let clip = table.enclosingScrollView?.contentView,
               table.frame.height <= clip.bounds.height + 1 {
                DispatchQueue.main.async { [onNearTop] in onNearTop() }
            }
        }

        // MARK: Updates

        private func layout(_ list: [TableRow]) -> [Shown] {
            let gap = 16 * min(environment.theme.scale, 1.2)
            var out: [Shown] = []
            out.reserveCapacity(list.count)
            for (i, row) in list.enumerated() {
                let top: CGFloat
                if i == 0 {
                    top = 22
                } else if row == .loading {
                    top = 0
                } else if let a = list[i - 1].item, let b = row.item, isQuiet(a), isQuiet(b) {
                    // Collapsed tool calls and thinking sit close together.
                    top = 2
                } else {
                    top = gap
                }
                out.append(Shown(row: row, top: top, bottom: i == list.count - 1 ? 23 : 0))
            }
            return out
        }

        /// Replaces the rows that changed: usually a few at the end (new
        /// content) or many at the start (earlier history).
        private func apply(_ next: [Shown]) {
            guard let table else { return }
            let old = rows
            var head = 0
            while head < min(old.count, next.count), old[head] == next[head] { head += 1 }
            var tail = 0
            while tail < min(old.count, next.count) - head, old[old.count - 1 - tail] == next[next.count - 1 - tail] { tail += 1 }
            keepingPlace {
                rows = next
                table.beginUpdates()
                table.removeRows(at: IndexSet(integersIn: head..<(old.count - tail)), withAnimation: [])
                table.insertRows(at: IndexSet(integersIn: head..<(next.count - tail)), withAnimation: [])
                table.endUpdates()
            }
        }

        /// Runs a change to the rows, then shows the end if it was in view, or
        /// else keeps the rows in view where they were.
        private func keepingPlace(_ change: () -> Void) {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return change() }
            if model?.atBottom != false {
                change()
                scrollToEnd()
                return
            }
            var anchor: (id: String, offset: CGFloat)?
            let first = table.row(at: NSPoint(x: 1, y: clip.bounds.minY + 1))
            if first >= 0, first < rows.count {
                anchor = (rows[first].row.id, table.rect(ofRow: first).minY - clip.bounds.minY)
            }
            change()
            if let anchor, let i = rows.firstIndex(where: { $0.row.id == anchor.id }) {
                let y = table.rect(ofRow: i).minY - anchor.offset
                if y != clip.bounds.minY { scroll(toY: y) }
            }
        }

        private func reloadVisible() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [0])
        }

        private func noteHeights(_ rows: IndexSet) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                table?.noteHeightOfRows(withIndexesChanged: rows)
            }
        }

        /// Rows opened or closed change kind and height.
        private func watchExpansion() {
            withObservationTracking { _ = expansion.open } onChange: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.expansionChanged()
                    self.watchExpansion()
                }
            }
        }

        private func expansionChanged() {
            guard let table else { return }
            var changed = IndexSet()
            for (i, shown) in rows.enumerated() {
                guard let item = shown.row.item, let was = shownOpen[item.id] else { continue }
                if was != isOpen(item) { changed.insert(i) }
            }
            guard !changed.isEmpty else { return }
            for i in changed { measureNow(i) }
            keepingPlace {
                noteHeights(changed)
                table.reloadData(forRowIndexes: changed, columnIndexes: [0])
            }
        }

        // MARK: Scrolling

        func scrollToEnd() {
            if DebugHooks.scrollTop { return }
            guard let table, let clip = table.enclosingScrollView?.contentView else { return }
            scroll(toY: max(0, table.frame.height - clip.bounds.height))
        }

        private func scroll(toY y: CGFloat) {
            guard let scroll = table?.enclosingScrollView else { return }
            (scroll as? TranscriptScrollView)?.stopGliding()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func reveal(_ uuid: String) -> Bool {
            guard let i = rows.firstIndex(where: { $0.row.item.map { $0.id == uuid || $0.id.hasPrefix(uuid + "-") } ?? false }) else {
                return false
            }
            model?.atBottom = false
            center(i)
            // Rows around it settle their heights once drawn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.center(i) }
            return true
        }

        private func center(_ row: Int) {
            guard let table, let clip = table.enclosingScrollView?.contentView, row < table.numberOfRows else { return }
            let r = table.rect(ofRow: row)
            scroll(toY: min(max(0, r.midY - clip.bounds.height / 2), max(0, table.frame.height - clip.bounds.height)))
        }

        private func scrolled() {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return }
            let bottom = clip.bounds.maxY >= table.frame.height - 40
            if model?.atBottom != bottom { model?.atBottom = bottom }
            let near = clip.bounds.minY < clip.bounds.height
            guard near != nearTop || near else { return }
            nearTop = near
            // Not while following the end, and not from within the layout pass that moved it.
            if near, !bottom { DispatchQueue.main.async { [onNearTop] in onNearTop() } }
        }

        // MARK: Rows

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let shown = rows[row]
            if let line = nativeLine(shown) {
                return shown.top + shown.bottom + line.height(theme: environment.theme)
            }
            // A row whose content changed keeps its last height until it is
            // measured again: a streaming row's guessed height made everything
            // above it jump by a few points on each update.
            return heights[shown.row.id]?.height ?? estimate(shown)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let shown = rows[row]
            if let item = shown.row.item { shownOpen[item.id] = isOpen(item) }
            if let line = nativeLine(shown) {
                let cell = (tableView.makeView(withIdentifier: NativeLineCell.reuse, owner: nil) as? NativeLineCell) ?? NativeLineCell()
                cell.configure(line, shown: shown, theme: environment.theme, inner: inner, marks: marks) { [weak self] in
                    guard let self, let id = shown.row.item?.id else { return }
                    self.expansion.open[id] = true
                }
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: HostedRowCell.reuse, owner: nil) as? HostedRowCell) ?? HostedRowCell()
            cell.rowID = shown.row.id
            cell.host.rootView = content(shown)
            let key = key(shown)
            if heights[shown.row.id]?.key != key {
                let h = measure(cell)
                heights[shown.row.id] = (key, h)
                if abs(h - tableView.rect(ofRow: row).height) > 0.5 {
                    pending.insert(row)
                    // Not from within the table's own layout.
                    DispatchQueue.main.async { [weak self] in self?.flushHeights() }
                }
            }
            return cell
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table, abs(table.bounds.width - width) > 0.5 else { return }
            width = table.bounds.width
            keepingPlace {
                noteHeights(IndexSet(integersIn: 0..<rows.count))
                reloadVisible()
            }
        }

        private var inner: CGFloat {
            let theme = environment.theme
            let w = table?.bounds.width ?? 600
            return max(min(w, theme.readingWidth) - 2 * theme.gutter, 100)
        }

        private func isOpen(_ item: TranscriptItem) -> Bool {
            if case .tool = item.kind { return expansion.open[item.id] ?? DebugHooks.expandTools }
            return expansion.open[item.id] ?? false
        }

        private func nativeLine(_ shown: Shown) -> NativeLine? {
            guard let item = shown.row.item, !isOpen(item) else { return nil }
            switch item.kind {
            case .tool(let use, let result):
                let name = use.name ?? tr("Tool")
                guard name != "TodoWrite" else { return nil }
                return .tool(name: name, input: use.input ?? .object([:]), result: result, busy: busy, cwd: cwd)
            case .thinking:
                return .thinking
            default:
                return nil
            }
        }

        private func content(_ shown: Shown) -> TableRowContent {
            let id = shown.row.id
            var images: [PlatformImage] = []
            if case .outgoing(let message, _, _) = shown.row { images = self.images[message] ?? [] }
            return TableRowContent(row: shown.row, images: images, busy: busy, cwd: cwd,
                                   width: table?.bounds.width ?? 600, inner: inner,
                                   top: shown.top, bottom: shown.bottom,
                                   search: marks.search(id), marked: marks.marked(id),
                                   expansion: RowExpansion(store: expansion, row: id), environment: environment)
        }

        /// What a SwiftUI row's height depends on.
        private func key(_ shown: Shown) -> Int {
            var h = Hasher()
            h.combine(shown)
            h.combine(table?.bounds.width ?? 0)
            h.combine(busy)
            h.combine(marks.search(shown.row.id).query)
            if let item = shown.row.item { h.combine(isOpen(item)) }
            return h.finalize()
        }

        private func measure(_ cell: HostedRowCell) -> CGFloat {
            ceil(cell.host.sizeThatFits(in: CGSize(width: table?.bounds.width ?? 600, height: .greatestFiniteMagnitude)).height)
        }

        /// Measures a row right away (one opening or closing), so the table
        /// has its height before it is drawn.
        private func measureNow(_ row: Int) {
            let shown = rows[row]
            guard nativeLine(shown) == nil else { return }
            sizer.host.rootView = content(shown)
            heights[shown.row.id] = (key(shown), measure(sizer))
        }

        private func flushHeights() {
            guard !pending.isEmpty else { return }
            let changed = pending.filteredIndexSet { $0 < rows.count }
            pending = []
            // Rows above the view growing would push it down: keep it in place.
            keepingPlace { noteHeights(changed) }
        }

        private func estimate(_ shown: Shown) -> CGFloat {
            let base = shown.top + shown.bottom
            switch shown.row {
            case .item(let item):
                switch item.kind {
                case .assistant(let text): return base + 24 + CGFloat(text.count / 90) * 22
                case .user(let text, let images): return base + 50 + CGFloat(min(text.count, 1600) / 80) * 22 + (images.isEmpty ? 0 : 160)
                case .tool: return base + 280
                case .thinking: return base + 120
                default: return base + 32
                }
            case .empty: return base + 140
            default: return base + 30
            }
        }
    }
}

/// Glides a mouse wheel's steps instead of jumping by them; trackpads and
/// other precise devices scroll as the system does.
final class TranscriptScrollView: NSScrollView {
    /// Steps are this many times AppKit's.
    static let stepScale: CGFloat = 2.5
    /// Where the glide in progress ends.
    private var target: NSPoint?
    private var glide = 0

    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty,
              event.scrollingDeltaY != 0, let doc = documentView else {
            stopGliding()
            return super.scrollWheel(with: event)
        }
        let clip = contentView
        // The wheel's lines (accelerated by the system) times a line height,
        // from where the glide is heading. AppKit's own line (24 pt) moved a
        // long transcript too little per step.
        let step = event.scrollingDeltaY * max(verticalLineScroll, 1) * Self.stepScale
        var to = target ?? clip.bounds.origin
        to.y += doc.isFlipped ? -step : step
        to.y = min(max(to.y, 0), max(0, doc.frame.height - clip.bounds.height))
        guard to != clip.bounds.origin else { return }
        target = to
        glide += 1
        let current = glide
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(to)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.glide == current else { return }
                self.target = nil
                self.reflectScrolledClipView(clip)
            }
        }
    }

    /// Ends a glide where it is, for a scroll that sets the position directly.
    func stopGliding() {
        guard target != nil else { return }
        target = nil
        glide += 1
        let clip = contentView
        let here = clip.bounds.origin
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            clip.animator().setBoundsOrigin(here)
        }
    }
}

final class TranscriptTableView: NSTableView {
    // Keys go to the composer; rows aren't selected.
    override var acceptsFirstResponder: Bool { false }
}

/// A cell that knows which row it shows.
class TranscriptCell: NSTableCellView {
    var rowID: String?
}

// MARK: - SwiftUI rows

/// A transcript row hosted in SwiftUI, at the width the table gives it.
struct TableRowContent: View {
    var row: TableRow
    var images: [PlatformImage]
    var busy: Bool
    var cwd: String?
    var width: CGFloat
    var inner: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var search: SearchHighlight
    var marked: Bool
    var expansion: RowExpansion
    var environment: EnvironmentValues

    var body: some View {
        let theme = environment.theme
        rowBody(theme)
            // A cell reused for another row, or a row whose text changed, builds
            // its views anew. Updating a message's text view in place resets its
            // selection, whose accessibility notice reads the cell back while it
            // is being updated: a cycle SwiftUI reports at length, freezing the app.
            .id(identity)
            .environment(\.searchHighlight, search)
            .environment(\.rowExpansion, expansion)
            .background {
                if marked {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.c.focus.opacity(0.14))
                        .padding(-6)
                }
            }
            .frame(width: inner, alignment: .leading)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(width: width)
            .environment(\.self, environment)
    }

    private var identity: Int {
        var h = Hasher()
        h.combine(row)
        h.combine(search.query)
        h.combine(search.selected)
        return h.finalize()
    }

    @ViewBuilder
    private func rowBody(_ theme: Theme) -> some View {
        switch row {
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity)
        case .empty:
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28))
                Text(tr("No messages yet"))
            }
            .font(theme.font(.callout))
            .foregroundStyle(theme.c.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        case .item(let item):
            TranscriptRow(item: item, busy: busy, cwd: cwd)
                .equatable()
        case .outgoing(_, let text, let sent):
            UserMessageView(text: text, localImages: images, status: sent ? tr("Sent") : tr("Sending…"))
        case .partial(let p):
            PartialView(partial: p)
        case .activity(let text, let waiting):
            ActivityRow(text: text, waiting: waiting)
        }
    }
}

final class HostedRowCell: TranscriptCell {
    static let reuse = NSUserInterfaceItemIdentifier("hosted")
    let host = NSHostingController(rootView: TableRowContent(
        row: .loading, images: [], busy: false, cwd: nil, width: 0, inner: 0, top: 0, bottom: 0,
        search: SearchHighlight(), marked: false,
        expansion: RowExpansion(store: ExpansionStore(), row: ""), environment: EnvironmentValues()))

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        // Sized by the table alone: no constraints, no size reports while scrolling.
        host.sizingOptions = []
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.autoresizingMask = [.width, .height]
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - AppKit lines

/// A collapsed tool call or thinking block, drawn with AppKit.
enum NativeLine {
    case tool(name: String, input: JSONValue, result: Block?, busy: Bool, cwd: String?)
    case thinking

    /// Vertical inset of a collapsed line, as in ToolCallView.
    static let inset: CGFloat = 3

    @MainActor
    func height(theme: Theme) -> CGFloat {
        let size = theme.size(.caption)
        var fonts = [theme.nsText(size, weight: .medium)]
        if case .tool(let name, _, _, _, _) = self, ToolInfo.monoSummary(name) { fonts.append(theme.nsMono(size - 0.5)) }
        let line = fonts.map { NativeLineCell.metrics.defaultLineHeight(for: $0) }.max() ?? 14
        return ceil(max(line, size + 2)) + 2 * Self.inset
    }
}

final class NativeLineCell: TranscriptCell {
    static let reuse = NSUserInterfaceItemIdentifier("line")
    @MainActor static let metrics = NSLayoutManager()

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let status = NSImageView()
    private let spinner = NSProgressIndicator()
    private let chevron = NSImageView()
    private let hoverLayer = CALayer()
    private let markLayer = CALayer()
    private var line: NativeLine = .thinking
    private var top: CGFloat = 0
    private var inner: CGFloat = 0
    private var lineHeight: CGFloat = 0
    private var hover = false
    private var hoverColor = NSColor.clear
    private var hoverTextColor = NSColor.clear
    private var restingToolText: NSAttributedString?
    private var onOpen: () -> Void = {}

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        wantsLayer = true
        layer?.addSublayer(markLayer)
        layer?.addSublayer(hoverLayer)
        markLayer.cornerRadius = 8
        markLayer.cornerCurve = .continuous
        hoverLayer.cornerRadius = 6
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.isSelectable = false
        icon.imageScaling = .scaleNone
        status.imageScaling = .scaleNone
        chevron.imageScaling = .scaleNone
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        [icon, label, status, spinner, chevron].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ line: NativeLine, shown: TableTranscript.Coordinator.Shown, theme: Theme, inner: CGFloat,
                   marks: TableMarks, onOpen: @escaping () -> Void) {
        let id = shown.row.id
        rowID = id
        self.line = line
        self.top = shown.top
        self.inner = inner
        self.onOpen = onOpen
        lineHeight = line.height(theme: theme) - 2 * NativeLine.inset
        hoverColor = NSColor(theme.c.hover)
        hoverTextColor = NSColor(theme.c.textMuted)
        let size = theme.size(.caption)

        switch line {
        case .tool(let name, let input, let result, let busy, let cwd):
            icon.image = Self.symbol(ToolInfo.icon(name), size: size - 1)
            icon.contentTintColor = NSColor(ToolInfo.tint(name, theme)).withAlphaComponent(0.8)
            let text = NSMutableAttributedString(string: ToolInfo.title(name) + "  ", attributes: [
                .font: theme.nsText(size, weight: .medium), .foregroundColor: NSColor(theme.c.textMuted),
            ])
            // Long commands are cut in the middle anyway; laying out all of one costs more.
            var summary = ToolInfo.summary(name, input, cwd: cwd).replacingOccurrences(of: "\n", with: " ")
            if summary.count > 400 { summary = summary.prefix(200) + "…" + summary.suffix(200) }
            text.append(NSAttributedString(string: summary, attributes: [
                .font: ToolInfo.monoSummary(name) ? theme.nsMono(size - 0.5) : theme.nsText(size),
                .foregroundColor: NSColor(theme.c.textFaint),
            ]))
            text.addAttribute(.paragraphStyle, value: Self.middle, range: NSRange(location: 0, length: text.length))
            label.attributedStringValue = marks.search(id).apply(text)
            restingToolText = label.attributedStringValue
            status.isHidden = false
            spinner.stopAnimation(nil)
            if let result {
                let error = result.isError == true
                status.image = Self.symbol(error ? "xmark.circle.fill" : "checkmark.circle.fill", size: size - 1)
                status.contentTintColor = error ? NSColor(theme.c.danger) : NSColor(theme.c.success).withAlphaComponent(0.85)
            } else if busy {
                status.isHidden = true
                spinner.startAnimation(nil)
            } else {
                status.image = Self.symbol("circle.dashed", size: size - 1)
                status.contentTintColor = NSColor(theme.c.textFaint)
            }
            setAccessibilityLabel(ToolInfo.title(name) + " " + summary)
        case .thinking:
            restingToolText = nil
            icon.image = Self.symbol("sparkle", size: size)
            icon.contentTintColor = NSColor(theme.c.textFaint)
            label.attributedStringValue = NSAttributedString(string: tr("Thinking"), attributes: [
                .font: theme.nsText(size), .foregroundColor: NSColor(theme.c.textFaint),
            ])
            status.isHidden = true
            spinner.stopAnimation(nil)
            setAccessibilityLabel(tr("Thinking"))
        }
        chevron.image = Self.symbol("chevron.right", size: max(9, theme.size(.small) - 1), weight: .semibold)
        chevron.contentTintColor = isTool ? hoverTextColor : NSColor(theme.c.textFaint)
        markLayer.backgroundColor = marks.marked(id) ? NSColor(theme.c.focus).withAlphaComponent(0.14).cgColor : nil
        hover = false
        updateHover()
        needsLayout = true
    }

    /// Attributed text keeps its own line breaking: cut in the middle.
    private static let middle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        return p
    }()

    private static var symbols: [String: NSImage] = [:]

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name) \(size) \(weight.rawValue)"
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        symbols[key] = image
        return image
    }

    private var isTool: Bool {
        if case .tool = line { return true }
        return false
    }

    /// The line itself, below the gap above it.
    private var lineRect: NSRect {
        let h = lineHeight + 2 * NativeLine.inset
        return NSRect(x: (bounds.width - inner) / 2, y: isFlipped ? top : bounds.height - top - h, width: inner, height: h)
    }

    override func layout() {
        super.layout()
        let rect = lineRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = rect
        markLayer.frame = rect.insetBy(dx: -6, dy: -6)
        CATransaction.commit()

        func place(_ view: NSView, x: CGFloat, size: NSSize) {
            view.frame = NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        }
        var x = rect.minX + 6
        let iconSize = icon.image?.size ?? .zero
        place(icon, x: x + (14 - iconSize.width) / 2, size: iconSize)
        x += 14 + 6
        let chevronSize = chevron.image?.size ?? .zero
        let labelSize = label.intrinsicContentSize
        if isTool {
            // [icon] title summary … [status] [chevron], as the SwiftUI line.
            var right = rect.maxX - 6
            place(chevron, x: right - chevronSize.width, size: chevronSize)
            right -= chevronSize.width + 6
            let statusSize = status.image?.size ?? NSSize(width: 12, height: 12)
            place(status, x: right - statusSize.width, size: statusSize)
            place(spinner, x: right - 12, size: NSSize(width: 12, height: 12))
            right -= max(statusSize.width, 12) + 10
            place(label, x: x, size: NSSize(width: max(0, min(labelSize.width, right - x)), height: labelSize.height))
        } else {
            place(label, x: x, size: labelSize)
            place(chevron, x: label.frame.maxX + 6, size: chevronSize)
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        if let restingToolText {
            let text = NSMutableAttributedString(attributedString: restingToolText)
            let range = NSRange(location: 0, length: text.length)
            restingToolText.enumerateAttribute(.backgroundColor, in: range) { background, run, _ in
                if background == nil { text.addAttribute(.foregroundColor, value: hoverTextColor, range: run) }
            }
            label.attributedStringValue = text
        }
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        if let restingToolText { label.attributedStringValue = restingToolText }
        updateHover()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHover()
    }

    private func updateHover() {
        // Tool lines show their chevron and a highlight on hover; thinking always shows its chevron.
        chevron.isHidden = isTool && !hover
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Layer colors are static once converted to CGColor. Pointer events do
        // not run in the view's drawing appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverLayer.backgroundColor = isTool && hover ? hoverColor.cgColor.copy(alpha: 0.6) : nil
        }
        CATransaction.commit()
    }

    // A click in a window in the background opens the line too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let rect = lineRect
        let hit = isTool ? rect.contains(p) : (p.y >= rect.minY && p.y <= rect.maxY && p.x <= chevron.frame.maxX + 6)
        if hit { onOpen() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen()
        return true
    }
}
#endif
