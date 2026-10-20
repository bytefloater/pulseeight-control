import Foundation
import Testing

/// Every word a person reads in this app comes from the shared catalog (`PulseEightCore.Strings`), so it can be translated and so
/// the macOS and Windows apps say the same things. This fails if a SwiftUI control is given a string literal as its text.
///
/// What is allowed: `Text(verbatim: ...)` for text that is the same in every language (an example IP address), SF Symbol
/// names (`systemImage:`), and strings built from data (an address, a port name). Anything else goes in the catalog.
@Suite struct NoHardcodedTextTests {
    /// Controls whose first argument is the text people read.
    static let textInitialisers = [
        "Text", "Button", "Label", "Section", "Toggle", "Picker", "LabeledContent", "TextField", "SecureField", "ProgressView",
        "ContentUnavailableView", "ControlRow", "Menu", "CommandMenu", "Window", "Link", "DisclosureGroup", "GroupBox",
    ]
    /// Modifiers whose first argument is text.
    static let textModifiers = ["help", "navigationTitle", "alert", "confirmationDialog", "accessibilityLabel", "accessibilityHint", "badge"]

    static var sourceFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PulseEightControl")
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: sourceFolder, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The text of a literal that starts right after `opening` and contains a letter: that is a word, not a symbol or number.
    static func hardcodedText(in line: String) -> [String] {
        var found: [String] = []
        let code = line.components(separatedBy: " // ").first ?? line
        let controls = textInitialisers.map { "\\b\($0)\\(\\s*\"" }
        let modifiers = textModifiers.map { "\\.\($0)\\(\\s*\"" }
        for pattern in controls + modifiers {
            var searchRange = code.startIndex..<code.endIndex
            while let match = code.range(of: pattern, options: .regularExpression, range: searchRange) {
                let start = match.upperBound
                if let end = code[start...].firstIndex(of: "\"") {
                    let literal = String(code[start..<end])
                    // What is interpolated (`\(count)`) is data, not words; only the text around it counts.
                    let words = literal.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
                    if words.range(of: "[A-Za-z]{2}", options: .regularExpression) != nil { found.append(literal) }
                }
                searchRange = match.upperBound..<code.endIndex
            }
        }
        return found
    }

    @Test func noControlIsGivenALiteralAsItsText() throws {
        var problems: [String] = []
        for file in try Self.swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                for text in Self.hardcodedText(in: line) {
                    problems.append("\(file.lastPathComponent):\(index + 1): \"\(text)\"")
                }
            }
        }
        #expect(problems.isEmpty, "Text that should come from the catalog (Strings): \n\(problems.joined(separator: "\n"))")
    }

    @Test func theCheckItselfCatchesWhatItShould() {
        #expect(Self.hardcodedText(in: #"Text("Hello there")"#) == ["Hello there"])
        #expect(Self.hardcodedText(in: #"Button("Save") { save() }"#) == ["Save"])
        #expect(Self.hardcodedText(in: #"Label("Matrix", systemImage: "network")"#) == ["Matrix"])
        #expect(Self.hardcodedText(in: #".help("Choose the matrix")"#) == ["Choose the matrix"])
        #expect(Self.hardcodedText(in: #".navigationTitle("Settings")"#) == ["Settings"])
        #expect(Self.hardcodedText(in: #"ControlRow("Restart") { x }"#) == ["Restart"])
    }

    @Test func theCheckLeavesAloneWhatIsNotWords() {
        #expect(Self.hardcodedText(in: #"Text(strings.text(.navRouting))"#).isEmpty)
        #expect(Self.hardcodedText(in: #"Text(verbatim: "192.168.1.150")"#).isEmpty)
        #expect(Self.hardcodedText(in: #"Image(systemName: "chevron.right")"#).isEmpty)
        #expect(Self.hardcodedText(in: #"Text("\(count)")"#).isEmpty, "an interpolation of data has no words")
        #expect(Self.hardcodedText(in: #"Text("80")"#).isEmpty)
    }

    @Test func theSourceFolderIsWhereTheCheckLooks() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 10, "found \(files.count) Swift files in \(Self.sourceFolder.path)")
        #expect(files.contains { $0.lastPathComponent == "SettingsView.swift" })
    }
}
