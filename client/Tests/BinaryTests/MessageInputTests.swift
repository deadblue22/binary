import XCTest
import SwiftUI
import AppKit
@testable import Binary

final class MessageInputTests: XCTestCase {
    @MainActor
    func testLongPasteRemainsEditableAndHeightIsBounded() {
        NSApplication.shared.setActivationPolicy(.accessory)
        var text = ""
        var submissions = 0
        struct Harness: View {
            @Binding var text: String
            @State var focused = true
            var submit: () -> Void
            var body: some View {
                MessageInput(text: $text, focused: $focused, onSubmit: submit)
                    .frame(width: 600)
            }
        }
        let host = NSHostingView(rootView: Harness(text: Binding(get: { text }, set: { text = $0 }), submit: { submissions += 1 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> MessageTextView? {
            if let editor = view as? MessageTextView { return editor }
            return view.subviews.compactMap(find).first
        }
        guard let editor = find(host) else { return XCTFail("Missing message editor") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(window.firstResponder === editor, "New composers must receive keyboard focus")
        let shortHeight = editor.inputHeight(width: 600)
        let pasted = String(repeating: "这是一段中文 English text，用于复现粘贴后的输入框卡顿。\n", count: 500)
        // Use a private pasteboard so the user's clipboard is left intact.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(pasted, forType: .string)
        let start = Date()
        XCTAssertTrue(editor.readSelection(from: pasteboard, type: .string))
        editor.didChangeText()
        host.layoutSubtreeIfNeeded()
        let height = editor.inputHeight(width: 600)
        XCTAssertTrue(text == pasted, "Paste must preserve all text")
        XCTAssertGreaterThan(height, shortHeight)
        XCTAssertLessThanOrEqual(height, shortHeight * 12)
        print("Long paste and layout: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "17,500 characters must not stall for seconds")
        editor.setSelectedRange(NSRange(location: (pasted as NSString).length, length: 0))
        editor.insertText("末尾", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(text == pasted + "末尾", "Editing/undo must preserve text, actual count: \(text.count)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(editor.bounds.height, editor.enclosingScrollView!.contentSize.height,
                             "Long drafts must scroll inside the capped viewport")
        editor.breakUndoCoalescing()
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        XCTAssertEqual(text, "")
        XCTAssertEqual(editor.inputHeight(width: 600), shortHeight)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.undoManager?.undo()
        XCTAssertTrue(text == pasted + "末尾", "Editing/undo must preserve text, actual count: \(text.count)")
        let newline = #selector(NSResponder.insertNewline(_:))
        XCTAssertTrue(editor.delegate?.textView?(editor, doCommandBy: newline) == true)
        XCTAssertEqual(submissions, 1)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        editor.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(editor.delegate?.textView?(editor, doCommandBy: newline) ?? true)
        XCTAssertEqual(submissions, 1, "Return during IME composition must not send")
    }
}
