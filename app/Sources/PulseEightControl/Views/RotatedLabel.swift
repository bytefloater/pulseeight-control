import SwiftCrossUI

#if os(macOS)
    import AppKit
    import AppKitBackend

    /// Text rotated to read bottom-to-top, for the routing grid's column headers.
    /// SwiftCrossUI has no rotation modifier, so on macOS this is a small AppKit view.
    struct RotatedLabel: NSViewRepresentable {
        var text: String

        func makeNSView(context: Context) -> RotatedTextView {
            RotatedTextView()
        }

        func updateNSView(_ view: RotatedTextView, context: Context) {
            view.text = text
        }
    }

    final class RotatedTextView: NSView {
        var text = "" {
            didSet {
                guard text != oldValue else { return }
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }

        private var attributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        }

        override var intrinsicContentSize: NSSize {
            let size = (text as NSString).size(withAttributes: attributes)
            // Rotated: the text's width becomes our height.
            return NSSize(width: ceil(size.height), height: ceil(size.width))
        }

        // Clicks and hovers belong to the SwiftCrossUI view wrapping this one.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.translateBy(x: bounds.width, y: 0)
            context.rotate(by: .pi / 2)
            (text as NSString).draw(at: .zero, withAttributes: attributes)
        }
    }
#else
    /// No rotation without AppKit, so the name is stacked one letter per line.
    struct RotatedLabel: View {
        var text: String

        var body: some View {
            VStack(spacing: 0) {
                ForEach(Array(text.reversed().enumerated()).map { Letter(id: $0.offset, char: String($0.element)) }) { letter in
                    Text(letter.char)
                }
            }
        }

        struct Letter: Identifiable {
            var id: Int
            var char: String
        }
    }
#endif
