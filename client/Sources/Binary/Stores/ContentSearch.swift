import Foundation
import Observation

/// Full-text matches for the sidebar search, from every server: sessions
/// whose messages contain the query, beyond the titles and first prompts the
/// client has on hand.
@MainActor
@Observable
final class ContentSearch {
    /// Server id → session id → match.
    private(set) var hits: [UUID: [String: ContentHit]] = [:]
    /// The query `hits` are for.
    private(set) var query = ""
    private(set) var running = false

    /// Queries shorter than this wait for more typing (one CJK character is enough).
    static func ready(_ q: String) -> Bool {
        q.count >= 2 || q.unicodeScalars.contains { !$0.isASCII }
    }

    /// Searches after a short pause in typing; call from `.task(id: query)`
    /// so a newer query cancels this one.
    func run(_ raw: String, on conns: [ServerConnection]) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.ready(q) else {
            hits = [:]
            query = ""
            running = false
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        running = true
        defer { if !Task.isCancelled { running = false } }
        let online = conns.filter { $0.status == .online }
        let found = await withTaskGroup(of: (UUID, [ContentHit]).self) { group in
            for c in online {
                group.addTask { (c.id, (try? await c.searchContent(q)) ?? []) }
            }
            var out: [UUID: [String: ContentHit]] = [:]
            for await (id, list) in group {
                out[id] = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            return out
        }
        guard !Task.isCancelled else { return }
        hits = found
        query = q
    }

    /// Matches for one server, when they belong to the query shown.
    func hits(for server: UUID, query raw: String) -> [String: ContentHit] {
        raw.trimmingCharacters(in: .whitespacesAndNewlines) == query ? hits[server] ?? [:] : [:]
    }
}

extension ContentHit.Snippet {
    /// The text with every word of `query` in bold.
    func highlighted(_ query: String) -> AttributedString {
        var out = AttributedString(text)
        let words = Set(query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        for w in words {
            var from = out.startIndex
            while from < out.endIndex, let r = out[from...].range(of: w, options: .caseInsensitive) {
                out[r].inlinePresentationIntent = .stronglyEmphasized
                from = r.upperBound
            }
        }
        return out
    }
}
