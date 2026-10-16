import SwiftCrossUI

/// A scroll view whose content is anchored to the top and centred horizontally. SwiftCrossUI's
/// ScrollView centres content that is smaller than the viewport on both axes, which floats a short
/// page in the middle of the window.
struct PageScroll<Content: View>: View {
    var axes: Axis.Set
    var content: Content

    init(axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(axes) {
                content.frame(
                    minWidth: geometry.size.width,
                    minHeight: geometry.size.height,
                    alignment: .top
                )
            }
        }
    }
}
