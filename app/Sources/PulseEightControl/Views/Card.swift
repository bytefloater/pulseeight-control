import SwiftCrossUI

/// SwiftCrossUI has no Form or Section, so this stands in for the old web UI's cards.
struct Card<Content: View>: View {
    var title: String
    var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

/// Key/value rows. Rows whose value is nil or empty are skipped, like the old `kv()` helper.
struct KeyValueRows: View {
    var pairs: [(String, String?)]
    var keyWidth = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visible, id: \.0) { pair in
                HStack(alignment: .top) {
                    Text(pair.0).foregroundColor(Color.gray).frame(width: keyWidth, alignment: .leading)
                    Text(pair.1)
                }
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
