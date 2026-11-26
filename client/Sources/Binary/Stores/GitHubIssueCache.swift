import Foundation
import Observation

/// Shared by inspectors using the same GitHub credentials.
@MainActor
@Observable
final class GitHubIssueCache {
    static let direct = GitHubIssueCache()
    static let lifetime: TimeInterval = 300

    struct Lookup {
        let details: GitHubIssueDetails?
        let expiresAt: Date
    }

    typealias Loader = @MainActor ([GitHubReference], APIClient?, @MainActor (String, GitHubIssueDetails?) -> Void) async -> Void

    private let server: APIClient?
    private let now: () -> Date
    private(set) var lookups: [String: Lookup] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    init(server: APIClient? = nil, now: @escaping () -> Date = Date.init) {
        self.server = server
        self.now = now
    }

    func refresh(_ rows: [GitHubReference], load: @escaping Loader = GitHubIssueAPI.load) async {
        let date = now()
        let pending = rows.filter { !loading.contains($0.id) && (lookups[$0.id]?.expiresAt ?? .distantPast) <= date }
        guard !pending.isEmpty else { return }
        loading.formUnion(pending.map(\.id))
        let visible = Set(rows.map(\.id))
        lookups = lookups.filter { $0.value.expiresAt > date || visible.contains($0.key) || loading.contains($0.key) }

        // A view can disappear mid-request. Finish the batch so the next inspector can use it.
        await Task {
            await load(pending, server) { id, details in
                self.lookups[id] = Lookup(details: details, expiresAt: self.now().addingTimeInterval(Self.lifetime))
                self.loading.remove(id)
            }
        }.value
    }

    func refreshDelay(for rows: [GitHubReference]) -> TimeInterval {
        let next = rows.compactMap { loading.contains($0.id) ? nil : lookups[$0.id]?.expiresAt }.min()
        return max(0, next?.timeIntervalSince(now()) ?? Self.lifetime)
    }
}
