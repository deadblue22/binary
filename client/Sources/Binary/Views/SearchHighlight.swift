import SwiftUI

/// Applied after Markdown styling, so cached text and copyable content stay intact.
struct SearchHighlight {
    var query = ""
    var selected = false

    private var background: Color { selected ? .orange : .yellow }

    func apply(_ source: AttributedString) -> AttributedString {
        guard !query.isEmpty else { return source }
        var text = source
        var start = text.startIndex
        while start < text.endIndex,
              let range = text[start...].range(of: query, options: .caseInsensitive) {
            text[range].backgroundColor = background
            text[range].foregroundColor = .black
            start = range.upperBound
        }
        return text
    }

    func apply(_ source: NSAttributedString) -> NSAttributedString {
        guard !query.isEmpty else { return source }
        let text = NSMutableAttributedString(attributedString: source)
        for range in TranscriptSearch.ranges(in: source.string, query: query) {
            text.addAttributes([.backgroundColor: PlatformColor(background),
                                .foregroundColor: PlatformColor(Color.black)], range: range)
        }
        return text
    }
}

extension EnvironmentValues {
    @Entry var searchHighlight = SearchHighlight()
}

struct SearchText: View {
    let text: AttributedString
    @Environment(\.searchHighlight) private var highlight

    init(_ text: String) { self.text = AttributedString(text) }
    init(_ text: AttributedString) { self.text = text }

    var body: some View { Text(highlight.apply(text)) }
}
