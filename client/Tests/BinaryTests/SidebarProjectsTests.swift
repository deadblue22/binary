import XCTest
@testable import Binary

final class SidebarProjectsTests: XCTestCase {
    private let server = UUID()

    private func node(_ id: String, _ cwd: String) -> SidebarNode {
        let d = Date()
        let s = SessionSummary(id: id, title: id, cwd: cwd, project: "", createdAt: d, updatedAt: d, state: "idle",
                               live: false, permissionMode: "default", pending: 0, messages: 1, managed: false)
        return SidebarNode(session: s, ref: SessionRef(server: server, session: id))
    }

    @MainActor
    func testSavedProjectsShowTheirNameAndOnlyFoldersAreDisambiguated() {
        let nodes = [node("1", "/a/app"), node("2", "/b/app"), node("3", "/c/web"),
                     node("4", "/a/app/.claude/worktrees/fix")]
        let groups = SidebarBuilder.projectGroups(nodes, server: server, org: SessionOrganizer(), names: ["/c/web": "Website"])
        XCTAssertEqual(groups.map(\.folder), ["/a/app", "/b/app", "/c/web"])
        XCTAssertEqual(groups.map(\.name), ["a/app", "b/app", "Website"])
        XCTAssertEqual(groups[0].nodes.map(\.session.id), ["1", "4"])
    }

    @MainActor
    func testSavedNameDoesNotCountAsAFolderNameClash() {
        let nodes = [node("1", "/a/app"), node("2", "/b/app")]
        let groups = SidebarBuilder.projectGroups(nodes, server: server, org: SessionOrganizer(), names: ["/b/app": "Backend"])
        XCTAssertEqual(groups.map(\.name), ["app", "Backend"])
    }

    @MainActor
    func testStarredOrderIsKeptAndEmptyStarredProjectsShow() {
        let nodes = [node("1", "/a/app"), node("2", "/c/web")]
        let groups = SidebarBuilder.projectGroups(nodes, server: server, org: SessionOrganizer(),
                                                  order: ["/c/web", "/z/empty", "/a/app"])
        XCTAssertEqual(groups.map(\.folder), ["/c/web", "/z/empty", "/a/app"])
        XCTAssertEqual(groups.map(\.nodes.count), [1, 0, 1])
        XCTAssertEqual(groups[1].name, "empty")
    }
}
