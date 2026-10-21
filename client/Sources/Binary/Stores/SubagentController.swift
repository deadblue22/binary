import Foundation
import Observation

/// Read-only transcript of one subagent run. Subagents have no event stream
/// of their own, so it polls: every 3 s while the parent is busy, every 15 s
/// otherwise.
@MainActor
@Observable
final class SubagentController: TranscriptSource {
    let conn: ServerConnection
    let sessionID: String
    let agentID: String

    private(set) var entries: [Entry] = []
    private(set) var items: [TranscriptItem] = []
    private(set) var loaded = false
    private(set) var refreshing = false
    var notice: String?

    let hasMore = false
    let loadingOlder = false
    let partial: Partial? = nil

    @ObservationIgnored private var task: Task<Void, Never>?

    init(conn: ServerConnection, sessionID: String, agentID: String) {
        self.conn = conn
        self.sessionID = sessionID
        self.agentID = agentID
    }

    var ref: SessionRef { SessionRef(server: conn.id, session: sessionID, agent: agentID) }
    var parent: SessionSummary? { conn.sessions[sessionID] }
    var info: SubagentInfo? { conn.subagents[sessionID]?.first { $0.id == agentID } }
    var title: String { info?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent" }

    var transcriptBusy: Bool { parent?.status.isBusy == true }
    var activityText: String? { nil }
    var waitingForApproval: Bool { false }
    var cwd: String? { parent?.cwd }

    func loadOlder() async {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let busy = self.parent?.status.isBusy == true
                try? await Task.sleep(nanoseconds: (busy ? 3 : 15) * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            let fresh = try await conn.subagentEntries(sessionID, agent: agentID)
            notice = nil
            if fresh.count != entries.count || fresh.last?.uuid != entries.last?.uuid || !loaded {
                entries = fresh
                items = TranscriptBuilder.items(from: fresh)
            }
        } catch let e as APIError where e.status == 404 {
            notice = conn.supportsSubagents ? tr("Subagent not found") : tr("This server can't show subagents (needs a newer binaryd)")
        } catch {
            notice = error.localizedDescription
        }
        loaded = true
    }
}
