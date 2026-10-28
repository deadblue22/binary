import SwiftUI

/// Block-level Markdown renderer: headings, paragraphs, lists, quotes, code
/// fences, tables and rules. Inline styling uses Foundation's Markdown parser.
struct MarkdownView: View {
    let text: String
    var role: TextRole = .body
    @Environment(\.theme) private var theme

    var body: some View {
        let segments = MarkdownCache.shared.segments(for: text, theme: theme, role: role)
        VStack(alignment: .leading, spacing: theme.size(role) * 0.75) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .flow(let attributed):
                    // One selectable run for consecutive paragraphs, headings and lists.
                    FlowText(text: attributed, linkColor: PlatformColor(theme.c.link))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .block(let block):
                    MarkdownBlockView(block: block, role: role)
                }
            }
        }
        .tint(theme.c.link)
    }
}

enum MDBlock: Hashable {
    case paragraph(String)
    case heading(Int, String)
    case code(lang: String, text: String)
    case list([MDListItem])
    case quote(String)
    case table([[String]])
    case rule
}

struct MDListItem: Hashable {
    var indent: Int
    var marker: String
    var text: String
    var checked: Bool?
}

@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()
    private var cache: [String: [MDBlock]] = [:]
    private var order: [String] = []
    private var inlineCache: [String: AttributedString] = [:]
    private var segmentCache: [String: [MDSegment]] = [:]
    private var segmentOrder: [String] = []

    /// Blocks grouped into selectable text runs, styled for the theme.
    func segments(for text: String, theme: Theme, role: TextRole) -> [MDSegment] {
        let key = "\(theme.style.rawValue)|\(theme.size.rawValue)|\(role)|" + text
        if let s = segmentCache[key] { return s }
        let s = MarkdownAttributed.segments(blocks(for: text), theme: theme, role: role)
        if text.count < 200_000 {
            segmentCache[key] = s
            segmentOrder.append(key)
            if segmentOrder.count > 600 { segmentCache[segmentOrder.removeFirst()] = nil }
        }
        return s
    }

    /// Inline Markdown with code spans styled for the theme.
    func inline(_ s: String, theme: Theme, size: CGFloat) -> AttributedString {
        let key = "\(theme.style.rawValue)|\(size)|" + s
        if let a = inlineCache[key] { return a }
        let a = MarkdownParser.styled(s, theme: theme, size: size)
        if inlineCache.count > 3000 { inlineCache.removeAll(keepingCapacity: true) }
        if s.count < 20_000 { inlineCache[key] = a }
        return a
    }

    func blocks(for text: String) -> [MDBlock] {
        if let b = cache[text] { return b }
        let b = MarkdownParser.parse(text)
        // Skip huge texts; the cache keeps the latest 400 (streaming text
        // changes on every update).
        if text.count < 200_000 {
            cache[text] = b
            order.append(text)
            if order.count > 400 {
                cache[order.removeFirst()] = nil
            }
        }
        return b
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var i = 0
        var para: [String] = []

        func flush() {
            if !para.isEmpty {
                blocks.append(.paragraph(para.joined(separator: "\n")))
                para = []
            }
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fence = String(t.prefix(3))
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(lang: lang, text: code.joined(separator: "\n")))
                continue
            }
            if t.isEmpty {
                flush()
                i += 1
                continue
            }
            if let h = heading(t) {
                flush()
                blocks.append(.heading(h.0, h.1))
                i += 1
                continue
            }
            if isRule(t) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    q.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(q.joined(separator: "\n")))
                continue
            }
            if t.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                var rows: [[String]] = [cells(t)]
                i += 2
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix("|") else { break }
                    rows.append(cells(l))
                    i += 1
                }
                blocks.append(.table(rows))
                continue
            }
            if listItem(line) != nil {
                flush()
                var items: [MDListItem] = []
                while i < lines.count {
                    if let item = listItem(lines[i]) {
                        items.append(item)
                        i += 1
                    } else if !items.isEmpty, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t") {
                        // Continuation of the previous item.
                        items[items.count - 1].text += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    private static func heading(_ t: String) -> (Int, String)? {
        var level = 0
        for c in t {
            if c == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " }
        guard chars.count >= 3, let f = chars.first, "-*_".contains(f) else { return false }
        return chars.allSatisfy { $0 == f }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func listItem(_ line: String) -> MDListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let t = line.dropFirst(indent)
        var marker = ""
        var rest: Substring
        if let f = t.first, "-*+".contains(f), t.dropFirst().first == " " {
            marker = "•"
            rest = t.dropFirst(2)
        } else {
            let digits = t.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count < 4 else { return nil }
            let after = t.dropFirst(digits.count)
            guard let p = after.first, p == "." || p == ")", after.dropFirst().first == " " else { return nil }
            marker = digits + "."
            rest = after.dropFirst(2)
        }
        var checked: Bool?
        if rest.hasPrefix("[ ] ") {
            checked = false
            rest = rest.dropFirst(4)
        } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            checked = true
            rest = rest.dropFirst(4)
        }
        return MDListItem(indent: indent / 2, marker: marker, text: String(rest), checked: checked)
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    static func styled(_ s: String, theme: Theme, size: CGFloat) -> AttributedString {
        var a = inline(s)
        for run in a.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            let codeFont: Font = theme.mono(size - 1)
            let fg: Color = theme.c.inlineCode
            let bg: Color = theme.c.inlineCodeBackground
            a[run.range].font = codeFont
            a[run.range].foregroundColor = fg
            a[run.range].backgroundColor = bg
        }
        return a
    }
}

/// Blocks drawn on their own: code, quotes, tables and rules. Paragraphs,
/// headings and lists go through FlowText.
struct MarkdownBlockView: View {
    let block: MDBlock
    var role: TextRole = .body
    @Environment(\.theme) private var theme

    private var size: CGFloat { theme.size(role) }

    private func inline(_ s: String) -> AttributedString {
        MarkdownCache.shared.inline(s, theme: theme, size: size)
    }

    var body: some View {
        switch block {
        case .code(let lang, let code):
            CodeBlockView(lang: lang, code: code)
        case .quote(let s):
            SearchText(inline(s))
                .font(theme.font(role))
                .lineSpacing(theme.lineSpacing)
                .foregroundStyle(theme.c.textMuted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.controlRadius - 2, style: .continuous).fill(theme.c.quoteBackground))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(theme.c.quoteBar).frame(width: 3)
                }
        case .table(let rows):
            MarkdownTable(rows: rows, role: role)
        case .rule:
            Rectangle()
                .fill(theme.c.border)
                .frame(height: 1)
                .padding(.vertical, size * 0.4)
        case .paragraph, .heading, .list:
            EmptyView()
        }
    }
}

struct MarkdownTable: View {
    let rows: [[String]]
    var role: TextRole = .body
    @Environment(\.theme) private var theme

    private var columns: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        // Fixed height: the cells fill their row, and the transcript stretches
        // short conversations to the window height, which rows would soak up.
        ViewThatFits(in: .horizontal) {
            grid.fixedSize(horizontal: true, vertical: true)
            grid.fixedSize(horizontal: false, vertical: true)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.c.border))
    }

    private var grid: some View {
        let size = theme.size(role == .body ? .callout : role)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { ci in
                        SearchText(MarkdownCache.shared.inline(ci < row.count ? row[ci] : "", theme: theme, size: size))
                            .font(theme.text(size).weight(ri == 0 ? .semibold : .regular))
                            .foregroundStyle(ri == 0 ? theme.c.heading : theme.c.text)
                            .lineSpacing(theme.lineSpacing * 0.5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(ri == 0 ? theme.c.tableHeader : (ri % 2 == 0 ? theme.c.tableRowAlt : theme.c.tableRow))
                            .overlay(alignment: .leading) {
                                if ci > 0 { Rectangle().fill(theme.c.border.opacity(0.6)).frame(width: 1) }
                            }
                    }
                }
                if ri < rows.count - 1 {
                    Rectangle()
                        .fill(theme.c.border.opacity(ri == 0 ? 1 : 0.6))
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let lang: String
    let code: String
    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: theme.size(.small)))
                Text(lang.isEmpty ? "code" : lang)
                    .font(theme.mono(theme.size(.small)))
                Spacer()
                Button {
                    copy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? tr("Copied") : tr("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(theme.font(.small))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.icon(size: 20, tint: copied ? theme.c.success : nil))
                .help(tr("Copy code"))
            }
            .foregroundStyle(theme.c.textFaint)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(theme.c.codeHeader)
            Rectangle().fill(theme.c.border.opacity(0.7)).frame(height: 1)
            ScrollView(.horizontal) {
                SearchText(code)
                    .font(theme.font(.mono))
                    .lineSpacing(theme.monoLineSpacing)
                    .foregroundStyle(theme.c.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .slimScrollers()
            }
        }
        .background(theme.c.code)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.c.border))
    }
}
