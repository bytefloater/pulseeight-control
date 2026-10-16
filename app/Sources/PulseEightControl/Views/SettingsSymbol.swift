import SwiftCrossUI

#if os(macOS)
    import AppKit
    import AppKitBackend

    /// Tint styles. Selected and unselected symbols are different *types*: SwiftCrossUI doesn't
    /// reliably re-run `updateNSView` when only a property changes, so switching types makes it
    /// build a fresh view with the right tint instead.
    protocol SymbolTint {
        static var color: NSColor { get }
    }

    enum AccentTint: SymbolTint { static var color: NSColor { .controlAccentColor } }
    enum WhiteTint: SymbolTint { static var color: NSColor { .white } }

    /// An SF Symbol, tinted. SwiftCrossUI has no image-from-symbol API, so this is a small AppKit
    /// view on macOS.
    struct SymbolImage<Tint: SymbolTint>: NSViewRepresentable {
        var name: String

        func makeNSView(context: Context) -> SymbolImageView {
            let view = SymbolImageView()
            view.imageScaling = .scaleProportionallyDown
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            view.contentTintColor = Tint.color
            return view
        }

        func updateNSView(_ view: SymbolImageView, context: Context) {}
    }

    /// The sidebar icon: accent-coloured, or white on the selection pill.
    struct SettingsSymbol: View {
        var name: String
        var selected: Bool

        var body: some View {
            if selected {
                SymbolImage<WhiteTint>(name: name)
            } else {
                SymbolImage<AccentTint>(name: name)
            }
        }
    }

extension Color {
    /// The user's system accent colour (resolved now; not updated live if they change it).
    static var systemAccent: Color {
        guard let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return Color.system(.blue) }
        return Color(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }
}

final class SymbolImageView: NSImageView {
        // Clicks belong to the row that wraps this.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
#else
    /// No symbols off macOS; the sidebar shows text only.
    struct SettingsSymbol: View {
        var name: String
        var selected: Bool

        var body: some View { EmptyView() }
    }

    extension Color {
        static var systemAccent: Color { Color.system(.blue) }
    }
#endif
