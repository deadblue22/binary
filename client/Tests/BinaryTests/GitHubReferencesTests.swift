import XCTest
@testable import Binary

final class GitHubReferencesTests: XCTestCase {
    func testCollectsAndMergesMentionsFromLoadedAndEarlierMessages() {
        let message = Entry(seq: 2, uuid: "new", kind: "user", blocks: [
            Block(type: "text", text: "见 [PR #7](https://github.com/Org/App/pull/7/files)，以及 org/app#7、other/app#7。Issue #8 和 #9，另见 PR 10"),
        ])
        var references = GitHubReferences()
        references.append([message])
        let tool = Entry(seq: 1, uuid: "old", kind: "assistant", blocks: [
            Block(type: "tool_use", input: .object(["url": .string("https://github.com/Other/App/issues/7#issuecomment-2")])),
            Block(type: "tool_result", text: "https://github.com/org/App/pull/7 #555"),
            Block(type: "thinking", text: "PR #99"),
            Block(type: "text", text: "PR #9, https://example.com/org/app/issues/123, #123abc"),
        ])
        var earlier = GitHubReferences()
        earlier.append([tool])
        references.merge(earlier)

        XCTAssertEqual(references.values.map(\.id), ["org/app#7", "other/app#7", "#8", "#9", "#10"])
        XCTAssertEqual(references.values.map(\.kind), ["PR", "Issue", "Issue", "PR", "PR"])
        XCTAssertEqual(references.values.first?.url?.absoluteString, "https://github.com/Org/App/pull/7")
        XCTAssertNil(references.values.last?.url)
    }

    func testEarlierPagesFollowUUIDsAndDiscardChangedGeneration() async throws {
        var cursors: [String] = []
        let history = try await GitHubReferences.earlier(than: "end", generation: "g") { cursor in
            cursors.append(cursor)
            let id = cursor == "end" ? "middle" : "start"
            let entry = Entry(seq: 1, uuid: id, kind: "assistant", blocks: [
                Block(type: "text", text: id == "middle" ? "PR #2" : "Issue #1 and PR #2"),
            ])
            return EntriesPage(entries: [entry], hasMore: id == "middle", gen: "g")
        }
        XCTAssertEqual(cursors, ["end", "middle"])
        XCTAssertEqual(history.values.map(\.label), ["PR #2", "Issue #1"])
        do {
            _ = try await GitHubReferences.earlier(than: "end", generation: "g") { _ in
                EntriesPage(entries: [], hasMore: false, gen: "replaced")
            }
            XCTFail("History from a replaced transcript was accepted")
        } catch is CancellationError {}
    }
}
