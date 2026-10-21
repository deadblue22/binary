import AppKit
import SwiftUI

/// A one-point line between columns that can be dragged to resize the column
/// on its `side`. Replaces the split views' floating, outlined panels.
struct ColumnDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Which side of the divider the resized column is on.
    let side: HorizontalEdge
    @Environment(\.theme) private var theme
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        Rectangle()
            .fill(theme.c.border)
            .frame(width: 1)
            .overlay {
                // A wider, invisible grip.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hover = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                let base = start ?? width
                                start = base
                                let delta = side == .leading ? g.translation.width : -g.translation.width
                                width = min(max(base + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in start = nil }
                    )
            }
            .zIndex(1)
    }
}
