import SwiftUI

/// Label/value rows for a grouped Form. Rows whose value is nil or empty are skipped.
struct KeyValueRows: View {
    var pairs: [(String, String?)]

    var body: some View {
        ForEach(visible, id: \.0) { key, value in
            LabeledContent(key) { Text(value).textSelection(.enabled) }
        }
    }

    private var visible: [(String, String)] {
        pairs.compactMap { key, value in
            guard let value, !value.isEmpty else { return nil }
            return (key, value)
        }
    }
}

func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
