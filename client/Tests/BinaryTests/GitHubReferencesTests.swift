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

        XCTAssertEqual(references.values.map(\.id), ["org/app#7", "other/app#7"])
        XCTAssertEqual(references.values.map(\.kind), ["PR", "Issue"])
        XCTAssertEqual(references.values.first?.url.absoluteString, "https://github.com/Org/App/pull/7")
        XCTAssertEqual(references.values.last?.url.absoluteString.lowercased(), "https://github.com/other/app/issues/7")
    }

    func testOnlyLinkableReferencesCountAcrossMessages() {
        let entries = [
            "https://github.com/one2x-ai/merouter/issues/764",
            "https://github.com/one2x-ai/merouter/pull/766",
            "Issue #764", "PR #765",
            "PR one2x-ai/merouter#767", "#766", "PR #767",
        ].enumerated().map { index, text in
            Entry(seq: Int64(index), uuid: String(index), kind: "assistant", blocks: [Block(type: "text", text: text)])
        }
        var references = GitHubReferences()
        references.append(entries)
        XCTAssertEqual(references.values.map(\.label), ["Issue #764", "PR #766", "PR #767"])
        XCTAssertEqual(references.values.last?.url.absoluteString, "https://github.com/one2x-ai/merouter/pull/767")
    }

    func testEarlierPagesFollowUUIDsAndDiscardChangedGeneration() async throws {
        var cursors: [String] = []
        let history = try await GitHubReferences.earlier(than: "end", generation: "g") { cursor in
            cursors.append(cursor)
            let id = cursor == "end" ? "middle" : "start"
            let entry = Entry(seq: 1, uuid: id, kind: "assistant", blocks: [
                Block(type: "text", text: id == "middle" ? "PR repo/app#2" : "Issue repo/app#1 and PR repo/app#2"),
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
