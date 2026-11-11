import XCTest
import SwiftUI
@testable import Binary

final class QuestionPromptTests: XCTestCase {
    @MainActor
    func testPromptLinksPreserveTextAndMarkdownDestinations() {
        let theme = Theme(style: .primary, size: .medium)
        let url = "https://example.com/demo?v=1&mode=B"
        let source = "😀介绍页 demo 已出 (\(url), 右上角切换 A/B)，选哪个方向？\n第二行"
        let prompt = QuestionCard.promptText(source, theme: theme)
        XCTAssertEqual(prompt.string, source)
        let range = (prompt.string as NSString).range(of: url)
        var linkedRange = NSRange()
        XCTAssertEqual(prompt.attribute(.link, at: range.location, effectiveRange: &linkedRange) as? URL,
                       URL(string: url))
        XCTAssertEqual(linkedRange, range)

        let markdown = QuestionCard.promptText(
            "[https://label.example](https://destination.example) `https://code.example`", theme: theme)
        XCTAssertEqual(markdown.string, "https://label.example https://code.example")
        XCTAssertEqual(markdown.attribute(.link, at: 0, effectiveRange: nil) as? URL,
                       URL(string: "https://destination.example"))
        let codeRange = (markdown.string as NSString).range(of: "https://code.example")
        XCTAssertNil(markdown.attribute(.link, at: codeRange.location, effectiveRange: nil))
        XCTAssertEqual(QuestionCard.promptText("", theme: theme).length, 0)
    }
}
