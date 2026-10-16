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
            ScrollView(.vertical) {
                if scrollsHorizontally {
                    ScrollView(.horizontal) { content }
                } else {
                    content.frame(minWidth: geometry.size.width, alignment: alignment)
                }
            }
            // Without this the scroll view is sized to its content and GeometryReader centres it.
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
