import AppKit
import SwiftUI

// Paragraphs, headings and lists of one message are drawn as a single
// read-only NSTextView, so a mouse selection can run across them (separate
// SwiftUI Text views each keep their own selection). Code blocks, quotes and
// tables stay separate views.

/// One piece of a rendered message: a run of flowing text, or a block view.
enum MDSegment {
    case flow(NSAttributedString)
    case block(MDBlock)
}

extension Theme {
    func nsText(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if isPrimary, Fonts.inter {
            let d = NSFontDescriptor(fontAttributes: [.family: "Inter"])
                .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
            if let f = NSFont(descriptor: d, size: size) { return f }
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    func nsMono(_ size: CGFloat) -> NSFont {
        if isPrimary, let name = Fonts.cascadia, let f = NSFont(name: name, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

enum MarkdownAttributed {
    static func isFlow(_ b: MDBlock) -> Bool {
        switch b {
        case .paragraph, .heading, .list: return true
        default: return false
        }
    }

    /// Groups blocks into flow runs and standalone blocks.
    static func segments(_ blocks: [MDBlock], theme: Theme, role: TextRole) -> [MDSegment] {
        var out: [MDSegment] = []
        var run: [MDBlock] = []
        func flush() {
            if !run.isEmpty { out.append(.flow(build(run, theme: theme, role: role))) }
            run = []
        }
        for b in blocks {
            if isFlow(b) { run.append(b) } else { flush(); out.append(.block(b)) }
        }
        flush()
        return out
    }

    static func build(_ blocks: [MDBlock], theme: Theme, role: TextRole) -> NSAttributedString {
        let size = theme.size(role)
        let out = NSMutableAttributedString()
        let text = NSColor(theme.c.text)
        let gap = size * 0.75
        for (bi, block) in blocks.enumerated() {
            let last = bi == blocks.count - 1
            switch block {
            case .paragraph(let s):
                let p = paragraphStyle(theme, after: last ? 0 : gap)
                out.append(inline(s, theme: theme, size: size, color: text, paragraph: p))
                if !last { out.append(newline(p)) }
            case .heading(let level, let s):
                let r: TextRole = level == 1 ? .h1 : level == 2 ? .h2 : level == 3 ? .h3 : .h4
                let hs = theme.size(r)
                let p = paragraphStyle(theme, before: bi == 0 ? 0 : (level <= 2 ? size * 0.6 : size * 0.3), after: last ? 0 : size * 0.45)
                out.append(inline(s, theme: theme, size: hs, color: NSColor(theme.c.heading), paragraph: p,
                                  weight: theme.isPrimary ? .semibold : .bold))
                if !last { out.append(newline(p)) }
            case .list(let items):
                for (ii, item) in items.enumerated() {
                    let lastItem = ii == items.count - 1
                    let indent = CGFloat(item.indent) * 20 + 2
                    let markerWidth: CGFloat = item.marker.count > 1 || item.checked != nil ? size * 1.5 : size * 1.1
                    let p = paragraphStyle(theme, after: lastItem ? (last ? 0 : gap) : size * 0.4)
                    p.firstLineHeadIndent = indent
                    p.headIndent = indent + markerWidth
                    p.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
                    let marker: String
                    if let checked = item.checked { marker = checked ? "☑" : "☐" } else { marker = item.marker }
                    out.append(NSAttributedString(string: marker + "\t", attributes: [
                        .font: theme.nsText(size, weight: .semibold),
                        .foregroundColor: NSColor(item.checked == true ? theme.c.success : theme.c.listMarker),
                        .paragraphStyle: p,
                    ]))
                    let body = inline(item.text, theme: theme, size: size, color: text, paragraph: p)
                    if item.checked == true {
                        let m = NSMutableAttributedString(attributedString: body)
                        m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: m.length))
                        m.addAttribute(.foregroundColor, value: NSColor(theme.c.textMuted), range: NSRange(location: 0, length: m.length))
                        out.append(m)
                    } else {
                        out.append(body)
                    }
                    if !(last && lastItem) { out.append(newline(p)) }
                }
            default:
                break
            }
        }
        return out
    }

    private static func paragraphStyle(_ theme: Theme, before: CGFloat = 0, after: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = theme.lineSpacing
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        return p
    }

    private static func newline(_ p: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.paragraphStyle: p])
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) as AppKit attributes.
    static func inline(_ s: String, theme: Theme, size: CGFloat, color: NSColor, paragraph: NSParagraphStyle,
                       weight: NSFont.Weight = .regular) -> NSAttributedString {
        let parsed = MarkdownParser.inline(s)
        let out = NSMutableAttributedString()
        let base = theme.nsText(size, weight: weight)
        let fm = NSFontManager.shared
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var font = base
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = theme.nsMono(size - 1)
                    attrs[.foregroundColor] = NSColor(theme.c.inlineCode)
                    attrs[.backgroundColor] = NSColor(theme.c.inlineCodeBackground)
                } else {
                    if intent.contains(.stronglyEmphasized) { font = fm.convert(font, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
                }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let url = run.link {
                attrs[.link] = url
            }
            attrs[.font] = font
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

/// Selectable, non-editable rich text sized to its content.
struct FlowText: NSViewRepresentable {
    let text: NSAttributedString
    let linkColor: NSColor
    @Environment(\.fileLinkHandler) private var links

    func makeCoordinator() -> LinkRouter { LinkRouter() }

    /// Links to files open in Binary's preview; web links go to the browser.
    final class LinkRouter: NSObject, NSTextViewDelegate {
        var handler: FileLinkHandler?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url, let handler else { return false }
            handler.open(url)
            return true
        }
    }

    func makeNSView(context: Context) -> FlowTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = FlowTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
        storage.setAttributedString(text)
        context.coordinator.handler = links
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: FlowTextView, context: Context) {
        context.coordinator.handler = links
        if tv.textStorage?.isEqual(to: text) == false {
            tv.textStorage?.setAttributedString(text)
        }
        tv.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: FlowTextView, context: Context) -> CGSize? {
        guard let layout = tv.layoutManager, let container = tv.textContainer else { return nil }
        var width = proposal.width ?? 10_000
        if !width.isFinite { width = 10_000 }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: proposal.width == nil ? ceil(used.width) : width, height: ceil(used.height))
    }
}

final class FlowTextView: NSTextView {
    // Let the transcript scroll when the wheel is over the text.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
