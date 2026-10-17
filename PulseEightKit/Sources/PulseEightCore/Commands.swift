import Foundation
import PulseEightKit

/// A text interface to every `AppCore` command, so a UI in another language only has to send and
/// receive JSON. Requests look like `{"cmd":"route","input":0,"output":2}`; responses are
/// `{"ok":true}` (with an optional `"value"`) or `{"ok":false,"error":"message"}`.
///
/// Commands: route, renamePort, setEdid, setBacklight, setStatusLed, retry, reconnect,
/// saveSettings, removeAdminPassword, setAppearance, setLanguage, strings, setHighlightGrid,
/// setShowStatusBar, validatePortName. See `docs/core-interface.md` for the fields of each.
extension AppCore {
    public func handle(requestJSON: String) async -> String {
        guard let data = requestJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["cmd"] as? String
        else { return Self.failure("Request must be a JSON object with a \"cmd\" string") }

        do {
            switch command {
            case "route":
                try await route(input: try int(object, "input"), output: try int(object, "output"))
            case "renamePort":
                try await renamePort(mode: try mode(object), bay: try int(object, "bay"), name: try string(object, "name"))
            case "setEdid":
                try await setEdidProfile(bay: try int(object, "bay"), profile: try int(object, "profile"))
            case "setBacklight":
                let raw = try string(object, "level").lowercased()
                guard let level = BacklightLevel(rawValue: raw) else { throw CoreError.invalid("level must be off, low or high") }
                try await setBacklight(level)
            case "setStatusLed":
                try await setStatusLED(on: try bool(object, "on"))
            case "retry":
                try await retry()
            case "reconnect":
                reconnect()
            case "saveSettings":
                try saveSettings(SettingsInput(
                    host: try string(object, "host"),
                    port: try text(object, "port", default: "80"),
                    timeout: try text(object, "timeout", default: "10"),
                    pollInterval: try text(object, "pollInterval", default: "5"),
                    detailPollInterval: try text(object, "detailPollInterval", default: "20"),
                    adminPassword: object["adminPassword"] as? String
                ))
            case "removeAdminPassword":
                try removeAdminPassword()
            case "setAppearance":
                guard let value = Appearance(rawValue: try string(object, "value")) else {
                    throw CoreError.invalid("value must be system, light or dark")
                }
                setAppearance(value)
            case "setLanguage":
                try setLanguage(try string(object, "value"))
            case "strings":
                // The whole text table for the language in force, as a JSON object in "value".
                let table = strings.allText
                guard let data = try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys]),
                      let text = String(data: data, encoding: .utf8)
                else { throw CoreError.failed("Couldn't encode the strings") }
                return Self.success(value: text)
            case "setHighlightGrid":
                setHighlightGrid(try bool(object, "on"))
            case "setShowStatusBar":
                setShowStatusBar(try bool(object, "on"))
            case "validatePortName":
                return Self.success(value: try validatePortName(try string(object, "name")))
            default:
                throw CoreError.invalid("Unknown command \"\(command)\"")
            }
            return Self.success()
        } catch {
            if case CoreError.notStarted = error { return Self.failure(strings.text(.errorNotStarted)) }
            return Self.failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Response encoding

    static func success(value: String? = nil) -> String {
        var object: [String: Any] = ["ok": true]
        if let value { object["value"] = value }
        return encode(object)
    }

    static func failure(_ message: String) -> String {
        encode(["ok": false, "error": message])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{\"ok\":false,\"error\":\"Couldn't encode response\"}" }
        return text
    }

    // MARK: Field access

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw CoreError.invalid("Missing text field \"\(key)\"") }
        return value
    }

    /// Accepts a JSON string or number, since form values are strings but callers may send numbers. A missing
    /// (or null) field takes the default; a field that is there but of another type is refused rather than
    /// quietly replaced by the default, which would save settings the caller never asked for.
    private func text(_ object: [String: Any], _ key: String, default fallback: String) throws -> String {
        guard let value = object[key], !(value is NSNull) else { return fallback }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        throw CoreError.invalid("\"\(key)\" must be text or a number")
    }

    private func int(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = (object[key] as? NSNumber)?.intValue else { throw CoreError.invalid("Missing number field \"\(key)\"") }
        return value
    }

    private func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] as? Bool else { throw CoreError.invalid("Missing true/false field \"\(key)\"") }
        return value
    }

    private func mode(_ object: [String: Any]) throws -> PortMode {
        guard let mode = PortMode(rawValue: try string(object, "mode")) else {
            throw CoreError.invalid("mode must be Input or Output")
        }
        return mode
    }
}
