import SwiftUI

/// How a row of content-sized tiles is broken into lines.
///
/// Split out of `FlowRow` as a pure function for the same reason
/// `PendingRecognitionPolicy` and `TagMerger` are pure: a `Layout`
/// conformance cannot be unit-tested without rendering a view, and this
/// project has no ViewInspector. The packing is the whole of the logic —
/// the `Layout` below is only placement — so this is where the tests go.
enum FlowPacking {
    struct Line: Equatable {
        /// Positions in the original, unsorted array. Indices rather than
        /// subviews so this stays free of SwiftUI.
        let indices: [Int]
        /// Width actually occupied, without a trailing gap.
        let width: CGFloat
        let height: CGFloat
    }

    /// Greedy, left-to-right, first-fit: each tile goes on the current line
    /// if it fits, otherwise it starts the next one.
    ///
    /// A tile wider than `maxWidth` on its own still gets a line of its own.
    /// The obvious alternative — refusing to place it — has no good answer
    /// (drop it? truncate it? loop forever re-testing the same item?), and a
    /// library tag is user-supplied text, so "wider than the screen" is a
    /// real input rather than a hypothetical one. It overflows, which is
    /// visible, instead of vanishing, which is not.
    static func lines(
        sizes: [CGSize],
        maxWidth: CGFloat,
        spacing: CGFloat
    ) -> [Line] {
        var result: [Line] = []
        var indices: [Int] = []
        var used = CGFloat.zero
        var height = CGFloat.zero

        for (index, size) in sizes.enumerated() {
            let projected = indices.isEmpty ? size.width : used + spacing + size.width
            if !indices.isEmpty && projected > maxWidth {
                result.append(Line(indices: indices, width: used, height: height))
                indices = []
                used = 0
                height = 0
            }
            used = indices.isEmpty ? size.width : used + spacing + size.width
            height = max(height, size.height)
            indices.append(index)
        }
        if !indices.isEmpty {
            result.append(Line(indices: indices, width: used, height: height))
        }
        return result
    }
}

/// Wraps subviews onto as many lines as they need, each as wide as its own
/// content.
///
/// `LazyVGrid` cannot do this: `GridItem(.adaptive)` computes a *column
/// count* from a fixed minimum width and then divides the width equally, so
/// every cell is the same size no matter what it holds. That is the right
/// shape for a table of records and the wrong shape for a bag of tags, where
/// the widths vary by an order of magnitude and equal columns waste most of
/// the row.
///
/// Requires the `Layout` protocol — **iOS 16.0**. The subviews are laid out
/// with `.unspecified`, so a tile that asks for `maxWidth: .infinity` will
/// report infinity here and be given its own line; tiles in this flow must
/// size to their content instead.
///
/// Not lazy. `Layout` receives every subview up front, so this builds all of
/// them at once. That is the trade for content-sized cells, and it is
/// affordable for the dozens of tags a library accumulates — the tiles are
/// two `Text`s each. A flow that had to hold thousands of items would want
/// a lazy implementation instead, which does not exist for this.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = FlowPacking.lines(
            sizes: sizes,
            maxWidth: proposal.width ?? .infinity,
            spacing: spacing
        )
        let height = lines.reduce(CGFloat.zero) { $0 + $1.height }
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = FlowPacking.lines(
            sizes: sizes,
            maxWidth: bounds.width,
            spacing: spacing
        )

        // Every tile in this flow is a fixed height, so `y` needs no
        // per-line vertical centering — the tallest tile in a line is by
        // definition every tile in it.
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
