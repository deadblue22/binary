import Foundation
import Observation

struct NewSessionDraft: Equatable {
    var serial: Int
    var parent: SessionRef?
    var group: String?
    var template: SessionRef?
    /// A project's +: start in this folder on `template`'s server instead.
    var folder: String?
}

struct TranscriptJump: Equatable {
    var ref: SessionRef
    /// The entry to show (rows of one entry share it as their id or id prefix).
    var uuid: String
    var serial: Int
}

@MainActor
@Observable
final class Navigation {
    var selection: SessionRef?
    /// A new session being set up in the detail column; it becomes a real
    /// session when its first message is sent.
    var draft: NewSessionDraft?
    /// A file a message links to, shown in the preview sheet.
    var filePreview: FilePreviewRequest?
    /// iOS: the open session's info sheet (the macOS info panel is a column).
    var showingInfo = false

    /// Opens a blank session: in `group`, starting from `template`'s folder
    /// (a group's +) or from `folder` on its server (a project's +), or as a
    /// child of `parent`.
    func newSession(parent: SessionRef? = nil, group: String? = nil, template: SessionRef? = nil, folder: String? = nil) {
        draft = NewSessionDraft(serial: (draft?.serial ?? 0) + 1, parent: parent?.sessionOnly, group: group, template: template, folder: folder)
        selection = nil
    }

    func newChildSession(of parent: SessionRef) { newSession(parent: parent) }
    /// Sidebar rows in display order, kept current by the sidebar. Not
    /// observed: nothing draws from it.
    @ObservationIgnored var visibleOrder: [SessionRef] = []
    /// Bumped to focus the sidebar search field.
    var searchRequest = 0
    /// Bumped for the open session to ask for a new title (the info panel's Rename).
    var renameRequest = 0
    /// A transcript row to scroll to, picked from a search match; the
    /// session's transcript takes it once it shows that session.
    var jump: TranscriptJump?

    /// Opens a session at one of its messages.
    func open(_ ref: SessionRef, at uuid: String) {
        jump = TranscriptJump(ref: ref, uuid: uuid, serial: (jump?.serial ?? 0) + 1)
        selection = ref
    }
    /// Set by the sidebar; scrolls a row into view without a state change
    /// (a state round-trip here cost a second full sidebar update per click).
    @ObservationIgnored var scrollHandler: ((SessionRef) -> Void)?

    func scroll(to ref: SessionRef) { scrollHandler?(ref) }
    /// A selection made on a sidebar row (a click, an arrow key): the row is
    /// in view already, so the sidebar doesn't look for it and scroll to it.
    @ObservationIgnored var pickedInSidebar: SessionRef?

    /// Selects a row the sidebar shows.
    func pick(_ ref: SessionRef) {
        if ref != selection { pickedInSidebar = ref }
        selection = ref
    }

    /// ⌘[ / ⌘]: bumped for the open session's composer to act on (nothing
    /// happens while no message box is shown).
    struct EffortStep: Equatable {
        var delta = 0
        var serial = 0
    }
    var effortStep = EffortStep()

    func stepEffort(_ d: Int) {
        effortStep = EffortStep(delta: d, serial: effortStep.serial + 1)
    }

    /// Moves the selection up or down the sidebar.
    func step(_ d: Int) {
        guard !visibleOrder.isEmpty else { return }
        let i = selection.flatMap { visibleOrder.firstIndex(of: $0) } ?? (d > 0 ? -1 : visibleOrder.count)
        let next = visibleOrder[max(0, min(visibleOrder.count - 1, i + d))]
        pick(next)
        scroll(to: next)
    }
}
