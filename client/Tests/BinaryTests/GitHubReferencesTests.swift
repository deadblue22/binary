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

    func testRecentPreviewAndExpandedListUseGitHubStateAndUpdateTime() throws {
        func detail(_ day: Int, _ state: String, pr: Bool = false, merged: Bool = false,
                    draft: Bool = false) throws -> GitHubIssueDetails {
            var payload: [String: Any] = ["title": "Title \(day)", "state": state,
                                          "updated_at": "2026-11-0\(day)T10:00:00Z", "draft": draft]
            if pr { payload["pull_request"] = merged ? ["merged_at": "2026-11-01T10:00:00Z"] : [:] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(GitHubIssueDetails.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let rows = (1...7).map { GitHubReference(repository: "org/app", number: String($0), kind: nil) }
        let details = try ["1": detail(1, "open"), "2": detail(2, "open", pr: true, draft: true),
                           "3": detail(3, "closed", pr: true, merged: true), "4": detail(4, "closed", pr: true),
                           "5": detail(5, "open"), "6": detail(6, "closed")]
        XCTAssertEqual(details["3"]?.title, "Title 3")
        XCTAssertEqual(details["6"]?.kind, "Issue")
        XCTAssertEqual(details["4"]?.kind, "PR")
        XCTAssertEqual(details["4"]?.status, .closed)
        XCTAssertEqual(details["3"]?.status, .merged)
        XCTAssertEqual(details["2"]?.status, .draft)
        let preview = GitHubReference.visible(rows, expanded: false) { details[$0.number] }
        XCTAssertEqual(preview.map(\.number), ["5", "2", "3", "6", "4"])
        let expanded = GitHubReference.visible(rows, expanded: true) { details[$0.number] }
        XCTAssertEqual(expanded.map(\.number), ["5", "1", "2", "3", "6", "4", "7"])
    }

    @MainActor
    func testSwitchingConversationsFetchesOnlyMissingOrExpiredIssues() async throws {
        var now = Date()
        let cache = GitHubIssueCache(now: { now })
        let first = GitHubReference(repository: "Org/App", number: "7", kind: "PR")
        let same = GitHubReference(repository: "org/app", number: "7", kind: nil)
        let other = GitHubReference(repository: "org/app", number: "8", kind: "Issue")
        let json = #"{"title":"Fix sync","state":"open","updated_at":"2026-11-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let details = try decoder.decode(GitHubIssueDetails.self, from: Data(json.utf8))
        var requests: [[String]] = []
        let load: GitHubIssueCache.Loader = { refs, _, receive in
            requests.append(refs.map(\.id))
            for ref in refs { receive(ref.id, ref.id == first.id ? details : nil) }
        }
        await cache.refresh([first], load: load)
        now.addTimeInterval(240)
        await cache.refresh([same, other], load: load)
        await cache.refresh([first], load: load)
        XCTAssertEqual(requests, [[first.id], [other.id]])
        XCTAssertEqual(cache.lookups[same.id]?.details?.title, "Fix sync")
        XCTAssertEqual(cache.refreshDelay(for: [same, other]), 60)
        now.addTimeInterval(60)
        await cache.refresh([other, same], load: load)
        XCTAssertEqual(requests, [[first.id], [other.id], [first.id]])
        XCTAssertNil(GitHubIssueCache().lookups[first.id])
    }

    @MainActor
    func testLeavingInspectorDoesNotCancelOrDuplicateAnInFlightLookup() async {
        let cache = GitHubIssueCache()
        let ref = GitHubReference(repository: "org/app", number: "7", kind: "PR")
        var finish: CheckedContinuation<Void, Never>?
        var inspector: Task<Void, Never>?
        await withCheckedContinuation { started in
            inspector = Task {
                await cache.refresh([ref]) { _, _, receive in
                    await withCheckedContinuation { finish = $0; started.resume() }
                    XCTAssertFalse(Task.isCancelled)
                    receive(ref.id, nil)
                }
            }
        }
        inspector?.cancel()
        await cache.refresh([ref]) { _, _, _ in XCTFail("Started a second request") }
        finish?.resume()
        await inspector?.value
        XCTAssertNotNil(cache.lookups[ref.id])
    }

    func testEarlierPagesFollowUUIDsAndDiscardChangedGeneration() async throws {
        var cursors: [String] = []
        var history = GitHubReferenceHistory(before: "end")
        try await history.scan(generation: "g") { cursor in
            cursors.append(cursor)
            let id = cursor == "end" ? "middle" : "start"
            let entry = Entry(seq: 1, uuid: id, kind: "assistant", blocks: [
                Block(type: "text", text: id == "middle" ? "PR repo/app#2" : "Issue repo/app#1 and PR repo/app#2"),
            ])
            return EntriesPage(entries: [entry], hasMore: id == "middle", gen: "g")
        } didRead: { history = $0 }
        XCTAssertNil(history.before)
        XCTAssertEqual(cursors, ["end", "middle"])
        XCTAssertEqual(history.references.values.map(\.label), ["PR #2", "Issue #1"])
        do {
            try await GitHubReferenceHistory(before: "end").scan(generation: "g") { _ in
                EntriesPage(entries: [], hasMore: false, gen: "replaced")
            } didRead: { _ in XCTFail("Accepted a page from a different generation") }
            XCTFail("History from a replaced transcript was accepted")
        } catch is CancellationError {}
    }

    func testCachedWindowRestoresReferencesAndResumesOnlyUnscannedPages() async throws {
        let entries = (1...6).map { n in
            Entry(seq: Int64(n), uuid: "row-\(n)", kind: "user", blocks: [
                Block(type: "text", text: "Issue org/app#\(n)")
            ])
        }
        // The two cache tiers discard different numbers of transcript rows.
        let original = CachedTranscript(gen: "g", lastSeq: 6, hasMore: true, entries: entries)
        let disk = original.keepingLast(4).keepingLast(2)
        let reopened = try JSONDecoder().decode(CachedTranscript.self, from: JSONEncoder().encode(disk))
        var history = try XCTUnwrap(reopened.referenceHistory)
        XCTAssertEqual(history.before, "row-1")
        XCTAssertEqual(history.references.values.map(\.number), ["1", "2", "3", "4"])
        var starts: [String] = []
        do {
            try await history.scan(generation: "g") { cursor in
                starts.append(cursor)
                if cursor == "older" { throw CancellationError() }
                return EntriesPage(entries: [Entry(seq: 0, uuid: "older", kind: "user",
                                                   blocks: [Block(type: "text", text: "PR org/app#7")])],
                                   hasMore: true, gen: "g")
            } didRead: { history = $0 }
        } catch is CancellationError {}
        try await history.scan(generation: "g") { cursor in
            starts.append(cursor)
            return EntriesPage(entries: [], hasMore: false, gen: "g")
        } didRead: { history = $0 }
        XCTAssertEqual(starts, ["row-1", "older", "older"])
        XCTAssertEqual(history.references.values.last?.number, "7")
        try await history.scan(generation: "g") { _ in
            XCTFail("A completed index requested history again")
            return EntriesPage(entries: [], hasMore: false, gen: "g")
        } didRead: { _ in XCTFail("Unexpected page") }
    }

}
