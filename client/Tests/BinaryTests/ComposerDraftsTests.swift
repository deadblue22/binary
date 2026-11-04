import XCTest
import AppKit
@testable import Binary

final class ComposerDraftsTests: XCTestCase {
    @MainActor
    func testNewSessionDraftSurvivesReopeningAndStaysSeparateFromSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let drafts = ComposerDrafts(fileURL: file)
        let ref = SessionRef(server: UUID(), session: "existing")
        drafts.setText("Existing draft", for: ref)
        drafts.newSessionText = "\n  未发送内容\n"
        let image = PendingImage(data: Data(), mediaType: "image/png", thumbnail: NSImage())
        drafts.newSessionImages = [image]
        XCTAssertEqual(drafts.newSessionImages, [image])
        drafts.save()

        let reopened = ComposerDrafts(fileURL: file)
        XCTAssertEqual(reopened.newSessionText, "\n  未发送内容\n")
        XCTAssertEqual(reopened.text(for: ref), "Existing draft")
        XCTAssertTrue(reopened.newSessionImages.isEmpty)
        reopened.newSessionText = "\n "
        XCTAssertEqual(reopened.newSessionText, "\n ")
        reopened.newSessionText = ""
        reopened.save()
        XCTAssertEqual(ComposerDrafts(fileURL: file).newSessionText, "")
        XCTAssertEqual(ComposerDrafts(fileURL: file).text(for: ref), "Existing draft")
    }
}
