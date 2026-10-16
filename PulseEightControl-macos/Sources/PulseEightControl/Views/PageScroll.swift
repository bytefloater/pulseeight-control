import SwiftCrossUI

/// A page-level scroll view. SwiftCrossUI's ScrollView centres content that is smaller than the
/// viewport: horizontally if it scrolls vertically, and on both axes if it scrolls both ways. So
/// vertical-only scrolling is used (content sits at the top), the content is widened to the
/// viewport so it can be aligned (centred, or leading for the grid), and pages that must also
/// scroll sideways nest a horizontal scroll view inside.
struct PageScroll<Content: View>: View {
    var alignment: Alignment
    var scrollsHorizontally: Bool
    var content: Content

    init(alignment: Alignment = .top, scrollsHorizontally: Bool = false, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.scrollsHorizontally = scrollsHorizontally
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            // Layout probing reports zero or infinite sizes. AppKit tolerates them, but WinUI aborts
            // the process (stowed exception) on an infinite or NaN width/height, so only finite,
            // positive sizes are ever turned into frames.
            let width = Self.usable(geometry.size.width)
            let height = Self.usable(geometry.size.height)
            ScrollView(.vertical) {
                if scrollsHorizontally {
                    ScrollView(.horizontal) { content }
                } else {
                    content.frame(minWidth: width, alignment: alignment)
                }
            }
            // Without this the scroll view is sized to its content and GeometryReader centres it.
            .frame(width: width, height: height)
        }
    }

    static func usable(_ length: Double) -> Double? {
        length.isFinite && length > 0 ? length : nil
    }
}
