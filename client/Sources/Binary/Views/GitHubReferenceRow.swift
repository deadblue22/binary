import SwiftUI
#if os(macOS)
import AppKit
#endif

struct GitHubReferenceRow: View {
    let row: GitHubReference
    let lookup: GitHubIssueCache.Lookup?
    @Environment(\.theme) private var theme
    #if os(macOS)
    @State private var hovered = false
    @State private var showPreview = false
    #endif

    private var details: GitHubIssueDetails? { lookup?.details }
    private var kind: String? { details?.kind ?? row.kind }
    private var title: String { details?.title ?? (lookup == nil ? tr("Loading…") : tr("Details unavailable")) }
    private var status: (label: String, color: Color)? {
        switch details?.status {
        case .open: return (tr("Still open"), theme.c.success)
        case .draft: return (tr("Draft"), theme.c.textMuted)
        case .merged: return (tr("Merged"), theme.c.external)
        case .closed: return (tr("Closed"), kind == "PR" ? theme.c.danger : theme.c.external)
        case nil: return nil
        }
    }

    private var icon: some View {
        GitHubStateIcon(kind: kind, status: details?.status)
            .frame(width: 15, height: 15)
            .foregroundStyle(status?.color ?? theme.c.textMuted)
            .accessibilityHidden(true)
    }

    var body: some View {
        Link(destination: row.url) {
            HStack(spacing: 6) {
                icon
                Text("#" + row.number)
                    .font(theme.font(.callout).weight(.semibold))
                    .foregroundStyle(theme.c.text)
                    .fixedSize()
                Text(title)
                    .font(theme.font(.callout))
                    .foregroundStyle(theme.c.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            .frame(minHeight: 26)
            .background(hovered ? theme.c.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            #else
            .frame(minHeight: 44)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([kind, row.id, title, status?.label].compactMap { $0 }.joined(separator: ", "))
        #if os(macOS)
        .onHover { hovered = $0 }
        .task(id: hovered) {
            showPreview = false
            guard hovered else { return }
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            showPreview = true
        }
        .background {
            if hovered && showPreview {
                HoverCardAnchor(content: preview)
                    .allowsHitTesting(false)
            }
        }
        #else
        .contextMenu {
            Link(tr("Open on GitHub"), destination: row.url)
        } preview: {
            preview
        }
        #endif
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                icon
                Text(row.repository + "#" + row.number)
                    .font(theme.font(.caption).weight(.medium))
                    .foregroundStyle(theme.c.link)
                if let status {
                    Text(status.label)
                        .font(theme.font(.caption))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(status.color.opacity(0.14), in: Capsule())
                }
            }
            Text(title)
                .font(theme.font(.callout).weight(.semibold))
                .foregroundStyle(theme.c.heading)
                .fixedSize(horizontal: false, vertical: true)
            if let details {
                Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 2) {
                    if let head = details.head?.ref, let base = details.base?.ref {
                        field(tr("Branch"), head + " → " + base)
                    }
                    if let author = details.user?.login { field(tr("Author"), "@" + author) }
                    field(tr("Updated"), Format.relative(details.updatedAt))
                }
                if let body = details.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                    Divider()
                    Text(verbatim: String(body.prefix(512)))
                        .foregroundStyle(theme.c.textMuted)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(theme.font(.caption))
        .padding(12)
        .frame(width: 310, alignment: .leading)
        .card(fill: theme.c.surface, shadow: false)
        .fixedSize()
    }

    private func field(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.c.textMuted).fixedSize()
            Text(value).foregroundStyle(theme.c.text).lineLimit(2)
        }
    }
}

/// The branch shape identifies a PR even when the status colors are indistinguishable.
private struct GitHubStateIcon: View {
    let kind: String?
    let status: GitHubIssueDetails.Status?

    var body: some View {
        if status == nil {
            Image(systemName: "questionmark.circle").resizable().scaledToFit()
        } else if kind != "PR" {
            Image(systemName: status == .closed ? "checkmark.circle" : "circle.circle")
                .resizable().scaledToFit()
        } else {
            Canvas { context, size in
                context.scaleBy(x: size.width / 16, y: size.height / 16)
                let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                func node(_ x: CGFloat, _ y: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: x - 1.7, y: y - 1.7, width: 3.4, height: 3.4))
                }
                var path = Path()
                path.addPath(node(3.5, 3))
                path.addPath(node(3.5, 13))
                path.move(to: CGPoint(x: 3.5, y: 5))
                path.addLine(to: CGPoint(x: 3.5, y: 11))
                path.addPath(node(12, 13))
                switch status {
                case .merged:
                    path.move(to: CGPoint(x: 3.5, y: 5))
                    path.addQuadCurve(to: CGPoint(x: 12, y: 11), control: CGPoint(x: 4, y: 10))
                case .closed:
                    path.move(to: CGPoint(x: 12, y: 11))
                    path.addLine(to: CGPoint(x: 12, y: 8))
                    path.move(to: CGPoint(x: 10, y: 2))
                    path.addLine(to: CGPoint(x: 14, y: 6))
                    path.move(to: CGPoint(x: 14, y: 2))
                    path.addLine(to: CGPoint(x: 10, y: 6))
                case .draft:
                    var dashed = Path()
                    dashed.move(to: CGPoint(x: 12, y: 3))
                    dashed.addLine(to: CGPoint(x: 12, y: 10))
                    context.stroke(dashed, with: .foreground, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [1, 3]))
                case .open:
                    path.move(to: CGPoint(x: 12, y: 11))
                    path.addLine(to: CGPoint(x: 12, y: 6))
                    path.addQuadCurve(to: CGPoint(x: 9, y: 3.5), control: CGPoint(x: 12, y: 3.5))
                    path.addLine(to: CGPoint(x: 7.5, y: 3.5))
                    path.move(to: CGPoint(x: 9.5, y: 1.5))
                    path.addLine(to: CGPoint(x: 7.5, y: 3.5))
                    path.addLine(to: CGPoint(x: 9.5, y: 5.5))
                case nil: break
                }
                context.stroke(path, with: .foreground, style: stroke)
            }
        }
    }
}

#if os(macOS)
/// A read-only hover card can extend outside the inspector without taking focus or intercepting clicks.
private struct HoverCardAnchor<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> Anchor {
        Anchor(content: content)
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.host.rootView = content
        view.positionCard()
    }

    final class Anchor: NSView {
        let host: NSHostingView<Content>
        private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: true)

        init(content: Content) {
            host = NSHostingView(rootView: content)
            super.init(frame: .zero)
            panel.contentView = host
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = false
        }

        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if panel.parent != newWindow {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); positionCard() }
        override func layout() { super.layout(); positionCard() }

        func positionCard() {
            guard let window, let screen = window.screen, !visibleRect.isEmpty else { return }
            let row = window.convertToScreen(convert(bounds, to: nil))
            let area = screen.visibleFrame.insetBy(dx: 5, dy: 5)
            let size = host.fittingSize
            let left = row.minX - size.width - 8
            let x = left >= area.minX ? left : min(row.maxX + 8, area.maxX - size.width)
            let y = min(max(row.midY - size.height / 2, area.minY), area.maxY - size.height)
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
            if panel.parent == nil {
                window.addChildWindow(panel, ordered: .above)
                panel.orderFront(nil)
            }
        }
    }
}
#endif
