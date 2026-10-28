import Foundation

/// One result per matching message, in conversation order.
enum TranscriptSearch {
    static func matches(in items: [TranscriptItem], query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        return items.compactMap { item in
            let text: String
            switch item.kind {
            case .user(let value, _), .assistant(let value), .thinking(let value):
                text = value
            case .tool(let use, let result):
                text = [use.name, use.input?.pretty, result?.text].compactMap { $0 }.joined(separator: "\n")
            case .system(let subtype, let value, _, _):
                text = subtype + "\n" + value
            case .result(let entry):
                text = entry.text ?? ""
            }
            return text.range(of: query, options: .caseInsensitive) == nil ? nil : item.id
        }
    }
}
