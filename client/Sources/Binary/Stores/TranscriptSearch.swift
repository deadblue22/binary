import Foundation

/// One result per matching message, newest first.
enum TranscriptSearch {
    struct Options: Hashable {
        var tools = false
        var thinking = false
    }

    static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            ranges.append(NSRange(range, in: text))
            start = range.upperBound
        }
        return ranges
    }

    static func matches(in items: [TranscriptItem], query: String, options: Options = Options()) -> [String] {
        guard !query.isEmpty else { return [] }
        return items.reversed().compactMap { item in
            let text: String
            switch item.kind {
            case .user(let value, _), .assistant(let value):
                text = value
            case .thinking(let value):
                guard options.thinking else { return nil }
                text = value
            case .tool(let use, let result):
                guard options.tools else { return nil }
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
