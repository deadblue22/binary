import XCTest
import SwiftUI
@testable import Binary

final class TranscriptSearchTests: XCTestCase {
    func testLiteralCaseInsensitiveSearchNewestFirst() {
        let items = [
            TranscriptItem(id: "a", kind: .user(text: "Hello hello", images: [])),
            TranscriptItem(id: "b", kind: .assistant(text: "HELLO [world]")),
            TranscriptItem(id: "c", kind: .thinking(text: "中文内容")),
        ]
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "hello"), ["b", "a"])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "[world]"), ["b"])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "中"), [])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: ""), [])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "missing"), [])
    }

    func testSearchesCollapsedToolInputsAndResults() {
        let tool = Block(type: "tool_use", name: "Bash", input: .object(["command": .string("echo needle")]))
        let result = Block(type: "tool_result", text: "output value")
        let items = [TranscriptItem(id: "tool", kind: .tool(use: tool, result: result))]
        for query in ["bash", "needle", "output value"] {
            XCTAssertEqual(TranscriptSearch.matches(in: items, query: query, options: .init(tools: true)), ["tool"])
        }
    }
    func testToolAndThinkingOptionsAreIndependent() {
        let items = [
            TranscriptItem(id: "text", kind: .assistant(text: "needle")),
            TranscriptItem(id: "thinking", kind: .thinking(text: "needle")),
            TranscriptItem(id: "tool", kind: .tool(use: Block(type: "tool_use", name: "needle"), result: nil)),
        ]
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "needle"), ["text"])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "needle", options: .init(tools: true)), ["tool", "text"])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "needle", options: .init(thinking: true)), ["thinking", "text"])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "needle", options: .init(tools: true, thinking: true)), ["tool", "thinking", "text"])
    }

    func testHighlightRangesUseUTF16AndLiteralMatching() {
        XCTAssertEqual(TranscriptSearch.ranges(in: "😀中文 HELLO hello [x]", query: "hello"),
                       [NSRange(location: 5, length: 5), NSRange(location: 11, length: 5)])
        XCTAssertEqual(TranscriptSearch.ranges(in: "[x]", query: "[x]"), [NSRange(location: 0, length: 3)])
        XCTAssertEqual(TranscriptSearch.ranges(in: "abc", query: ""), [])
    }

    func testHighlightPreservesFormattingAndDoesNotChangeSource() {
        var original = AttributedString("Hello hello")
        original.link = URL(string: "https://example.com")
        let highlighted = SearchHighlight(query: "hello").apply(original)
        XCTAssertEqual(String(highlighted.characters), "Hello hello")
        XCTAssertEqual(highlighted.runs.filter { $0.backgroundColor == .yellow }.count, 2)
        XCTAssertTrue(highlighted.runs.allSatisfy { $0.link == original.link })
        XCTAssertNil(original.backgroundColor)
        XCTAssertEqual(SearchHighlight().apply(original), original)

        let native = NSAttributedString(string: "😀HELLO hello", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
        let marked = SearchHighlight(query: "hello", selected: true).apply(native)
        XCTAssertNotNil(marked.attribute(.backgroundColor, at: 2, effectiveRange: nil))
        XCTAssertNotNil(marked.attribute(.backgroundColor, at: 8, effectiveRange: nil))
        XCTAssertEqual(marked.attribute(.font, at: 2, effectiveRange: nil) as? NSFont,
                       native.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertNil(native.attribute(.backgroundColor, at: 2, effectiveRange: nil))
    }

}
