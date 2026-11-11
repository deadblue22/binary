import XCTest
import SwiftUI
import AppKit
@testable import Binary

final class TranscriptImageLayoutTests: XCTestCase {
    @MainActor
    func testImageMessagesReserveTheSameHeightBeforeAndAfterLoading() {
        let image = NSImage(size: NSSize(width: 600, height: 900), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let text = "图片下面的文字应完整显示。\n第二行也应保留在消息区域内。"
        let theme = Theme(style: .primary, size: .medium)

        for width: CGFloat in [360, 800] {
            func height(_ view: UserMessageView) -> CGFloat {
                let host = NSHostingController(rootView: view.environment(\.theme, theme).frame(width: width))
                return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
            }
            let textHeight = height(UserMessageView(text: text, status: "Sent"))
            for count in [1, 2] {
                let loading = height(UserMessageView(text: text, imageKeys: Array(repeating: nil, count: count), status: "Sent"))
                let loaded = height(UserMessageView(text: text, localImages: Array(repeating: image, count: count), status: "Sent"))
                XCTAssertEqual(loading, loaded, accuracy: 1, "Image loading must not outgrow the cached message height")
                XCTAssertEqual(loading - textHeight, (count == 1 ? 240 : 150) + 6, accuracy: 1,
                               "The image strip must reserve its height without taking space from the text")
            }
        }
    }
}
