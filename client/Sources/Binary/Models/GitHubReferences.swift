import Foundation

/// GitHub shares one number sequence between issues and pull requests in a repository.
struct GitHubReference: Identifiable, Equatable {
    let repository: String?
    let number: String
    let kind: String?

    var id: String { (repository?.lowercased() ?? "") + "#" + number }
    var label: String { [kind, (repository ?? "") + "#" + number].compactMap { $0 }.joined(separator: " ") }
    var url: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)/\(kind == "PR" ? "pull" : "issues")/\(number)") }
    }
}

struct GitHubReferences {
    private var byID: [String: GitHubReference] = [:]
    private var order: [String] = []

    var values: [GitHubReference] { order.compactMap { byID[$0] } }

    /// Keep only references from each older page. The transcript retains its own scroll window.
    static func earlier(than first: String, generation: String,
                        pageBefore: (String) async throws -> EntriesPage) async throws -> Self {
        var history = Self()
        var cursor = first
        while true {
            try Task.checkCancellation()
            let page = try await pageBefore(cursor)
            try Task.checkCancellation()
            guard page.gen == nil || page.gen == generation else { throw CancellationError() }
            history.append(page.entries)
            guard page.hasMore == true, let next = page.entries.first?.uuid, next != cursor else { return history }
            cursor = next
        }
    }

    mutating func merge(_ other: GitHubReferences) {
        for reference in other.values { add(reference) }
    }

    private mutating func add(_ reference: GitHubReference) {
        if let existing = byID[reference.id] {
            guard existing.kind == nil, reference.kind != nil else { return }
        } else {
            order.append(reference.id)
        }
        byID[reference.id] = reference
    }

    // Consume a Markdown link's label along with its destination so [PR #12](…/pull/12)
    // contributes only the qualified reference. Stop before fragments and subpages.
    private static let link = #"(?:(?:\[[^\[\]\n]*\]\()?(?<![a-z0-9./@_-])(?:https?://)?github\.com/([a-z0-9-]+/[a-z0-9_.-]+)/(issues|pull)/([1-9][0-9]*)(?![a-z0-9_]))"#
    private static let short = #"(?<![a-z0-9_./#-])(?:(pull[ \t]+request|pr|issue)[ \t]*)?(?:([a-z0-9-]+/[a-z0-9_.-]+))?#([1-9][0-9]*)(?![a-z0-9_])"#
    private static let links = try! NSRegularExpression(pattern: link, options: .caseInsensitive)
    private static let typedNumber = #"(?<![a-z0-9_])(pull[ \t]+request|pr|issue)[ \t]+([1-9][0-9]*)(?![a-z0-9_])"#
    private static let mentions = try! NSRegularExpression(pattern: [link, short, typedNumber].joined(separator: "|"),
                                                           options: .caseInsensitive)

    private mutating func scan(_ text: String, linksOnly: Bool) {
        if linksOnly && !text.localizedCaseInsensitiveContains("github.com/") { return }
        let source = text as NSString
        let pattern = linksOnly ? Self.links : Self.mentions
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            if let repo = group(1), let number = group(3) {
                add(GitHubReference(repository: repo, number: number, kind: group(2)?.lowercased() == "pull" ? "PR" : "Issue"))
            } else if let number = group(6) ?? group(8) {
                let kind = (group(4) ?? group(7)).map { $0.lowercased() == "issue" ? "Issue" : "PR" }
                add(GitHubReference(repository: group(5), number: number, kind: kind))
            }
        }
    }

    private mutating func scanToolInput(_ value: JSONValue) {
        switch value {
        case .string(let text): scan(text, linksOnly: true)
        case .object(let fields):
            for field in fields.sorted(by: { $0.key < $1.key }) { scanToolInput(field.value) }
        case .array(let array):
            for item in array { scanToolInput(item) }
        default: break
        }
    }

    mutating func append(_ entries: [Entry]) {
        for entry in entries where entry.kind == "user" || entry.kind == "assistant" {
            for block in entry.blocks ?? [] {
                switch block.type {
                case "text", "tool_result": scan(block.text ?? "", linksOnly: block.type == "tool_result")
                case "tool_use": if let input = block.input { scanToolInput(input) }
                default: break
                }
            }
        }
    }
}
