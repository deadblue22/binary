import SwiftUI
#if os(macOS)
import AppKit

/// A scrolling editor avoids TextField's full-string cell-size calculation on each edit.
struct MessageInput: NSViewRepresentable {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var label: String = ""
    @Environment(\.theme) private var theme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = MessageTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async { coordinator?.parent.focused.wrappedValue = focused }
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? MessageTextView else { return }
        let font = (theme.isPrimary ? NSFont(name: "Inter", size: theme.size(.body)) : nil)
            ?? NSFont.systemFont(ofSize: theme.size(.body))
        if editor.font != font { editor.font = font }
        let color = NSColor(theme.c.text)
        if editor.textColor != color { editor.textColor = color; editor.insertionPointColor = color }
        let spacing = theme.lineSpacing * 0.6
        if editor.defaultParagraphStyle?.lineSpacing != spacing {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            editor.defaultParagraphStyle = paragraph
            editor.typingAttributes[.paragraphStyle] = paragraph
        }
        // Never replace the editor's contents while an input method owns marked text.
        if !editor.hasMarkedText(), editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
        editor.setAccessibilityLabel(label)
        if focused.wrappedValue, let window = editor.window, window.firstResponder !== editor {
            DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                guard let editor, coordinator?.parent.focused.wrappedValue == true else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let editor = scroll.documentView as? MessageTextView else { return nil }
        let width = max(1, proposal.width ?? 600)
        return CGSize(width: width, height: editor.inputHeight(width: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageInput
        init(_ parent: MessageInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func textView(_ textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.shift) || modifiers.contains(.option) { return false }
            parent.onSubmit()
            return true
        }
    }
}

final class MessageTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    /// Measure only the visible twelve-line viewport, not an unbounded text cell.
    func inputHeight(width: CGFloat) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer, let font else { return 20 }
        let line = ceil(layout.defaultLineHeight(for: font) + (defaultParagraphStyle?.lineSpacing ?? 0))
        let maximum = line * 12
        let size = NSSize(width: width, height: .greatestFiniteMagnitude)
        if container.size != size { container.size = size }
        layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: width, height: maximum), in: container)
        let used = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return min(maximum, max(line, ceil(used)))
    }
}
#endif
