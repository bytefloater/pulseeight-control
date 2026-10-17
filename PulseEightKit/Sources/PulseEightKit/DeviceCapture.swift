import Foundation

/// Saves the raw JSON of every read endpoint of a matrix, to turn a real device into test fixtures
/// (`p8ctl capture`). The bytes are kept exactly as the device sent them, because a quirk in how it
/// formats a value (`1.0` for an integer, `1` for a boolean) is the very thing the fixtures should catch.
public enum DeviceCapture {
    public struct File: Sendable, Equatable {
        public var name: String
        public var data: Data
    }

    public struct Result: Sendable {
        public var files: [File]
        /// Endpoints the device refused (one note each); a refusal doesn't abort the capture.
        public var skipped: [String]
    }

    /// Fields that identify the device itself (and, in an output's details, an attached screen).
    static let redactedKeys = ["Serial", "MAC"]

    /// - Parameter redact: replace serial numbers and MAC addresses with placeholders. Port names are
    ///   left alone, so check them before sharing a capture.
    public static func capture(from client: MatrixClient, redact: Bool = true) async throws -> Result {
        var files: [File] = []
        var skipped: [String] = []

        func record(_ name: String, _ data: Data) {
            files.append(File(name: name, data: redact ? Self.redact(data) : data))
        }

        record("system-details.json", try await client.rawResponse("/System/Details"))
        record("system-features.json", try await client.rawResponse("/system/features"))

        let listData = try await client.rawResponse("/Port/List")
        record("port-list.json", listData)
        let ports: [MatrixPort]
        do {
            ports = try JSONDecoder().decode(PortListResponse.self, from: listData).ports
        } catch {
            throw MatrixError.api("Unexpected response from /Port/List: \(error)")
        }

        for port in ports.sorted(by: { ($0.mode.rawValue, $0.bay) < ($1.mode.rawValue, $1.bay) }) {
            let kind = port.mode.rawValue.lowercased()
            do {
                record("port-details-\(kind)-\(port.bay).json", try await client.rawResponse("/Port/Details/\(port.mode.rawValue)/\(port.bay)"))
            } catch {
                skipped.append("\(port.mode.rawValue) \(port.bay): \(error.localizedDescription)")
            }
        }
        return Result(files: files, skipped: skipped)
    }

    /// Replaces the value of each redacted key with a placeholder, as text, so everything else in the reply
    /// stays byte for byte as the device sent it.
    static func redact(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        let keys = redactedKeys.joined(separator: "|")
        // Group 1 is the quoted key and colon; group 2 is the value (a string, or a number).
        guard let expression = try? NSRegularExpression(pattern: "(\"(?:\(keys))\"\\s*:\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"|-?[0-9][0-9.eE+-]*)") else { return data }

        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let valueRange = Range(match.range(at: 2), in: text) else { continue }
            text.replaceSubrange(valueRange, with: text[valueRange].hasPrefix("\"") ? "\"REDACTED\"" : "0")
        }
        return Data(text.utf8)
    }
}
