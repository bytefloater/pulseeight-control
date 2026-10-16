import SwiftCrossUI

/// A titled group in a form. SwiftCrossUI has no Form or Section; groups are separated by
/// dividers and laid out in a centred column, like System Settings.
struct FormSection<Content: View>: View {
    var title: String
    var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label with a right-aligned caption and a control, the macOS settings idiom.
struct FormRow<Content: View>: View {
    static var labelWidth: Double { 190 }

    var label: String
    var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).foregroundColor(Color.gray).frame(width: Self.labelWidth, alignment: .trailing)
            content
        }
    }
}

/// Key/value rows. Rows whose value is nil or empty are skipped, like the old `kv()` helper.
struct KeyValueRows: View {
    var pairs: [(String, String?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visible, id: \.0) { pair in
                FormRow(pair.0) { Text(pair.1) }
            }
        }
    }

    var visible: [(String, String)] {
        pairs.compactMap { key, value in
            guard let value, !value.isEmpty else { return nil }
            return (key, value)
        }
    }
}

func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
