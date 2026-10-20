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

/// A Form row with its title on the left and its control on the right, centred in the row.
///
/// A Picker, Toggle or LabeledContent row lays the control out against the title's text baseline, which in a grouped
/// Form leaves a control with more padding below it than above (about 2pt high on macOS 26). Putting both in an
/// HStack centres them on each other and in the row. The control's own label is hidden, because the title is the
/// label.
struct ControlRow<Control: View>: View {
    var title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            control.labelsHidden()
        }
    }
}

