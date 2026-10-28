import XCTest
@testable import Binary

final class TranscriptSearchTests: XCTestCase {
    func testLiteralCaseInsensitiveSearchInConversationOrder() {
        let items = [
            TranscriptItem(id: "a", kind: .user(text: "Hello hello", images: [])),
            TranscriptItem(id: "b", kind: .assistant(text: "HELLO [world]")),
            TranscriptItem(id: "c", kind: .thinking(text: "中文内容")),
        ]
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "hello"), ["a", "b"])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "[world]"), ["b"])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "中"), ["c"])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: ""), [])
        XCTAssertEqual(TranscriptSearch.matches(in: items, query: "missing"), [])
    }

    func testSearchesCollapsedToolInputsAndResults() {
        let tool = Block(type: "tool_use", name: "Bash", input: .object(["command": .string("echo needle")]))
        let result = Block(type: "tool_result", text: "output value")
        let items = [TranscriptItem(id: "tool", kind: .tool(use: tool, result: result))]
        for query in ["bash", "needle", "output value"] {
            XCTAssertEqual(TranscriptSearch.matches(in: items, query: query), ["tool"])
        }
    }
}
