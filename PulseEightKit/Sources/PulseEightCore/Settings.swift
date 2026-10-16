import Foundation
import PulseEightKit

public enum Appearance: String, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case system, light, dark

    public var description: String { rawValue.capitalized }
}

/// Everything persisted in settings.json. `matrix` uses the same keys as the old
/// legacy/PulseEightWeb/backend/config.json, minus `admin_password`.
public struct AppSettings: Codable, Equatable, Sendable {
    public var matrix = MatrixConfig()
    public var appearance: Appearance = .system
    /// Row/column highlight under the pointer in the routing grid.
    public var highlightGrid = true
    public var showStatusBar = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matrix = try c.decodeIfPresent(MatrixConfig.self, forKey: .matrix) ?? MatrixConfig()
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        highlightGrid = try c.decodeIfPresent(Bool.self, forKey: .highlightGrid) ?? true
        showStatusBar = try c.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? true
    }

    /// Missing or unreadable files give defaults.
    public static func load(from url: URL = ConfigPaths.settingsFile) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(to url: URL = ConfigPaths.settingsFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Per-OS location for settings. The admin password is not stored here (see `SecretStore`).
public enum ConfigPaths {
    public static let appFolder = "PulseEightControl"

    public static var directory: URL {
        let env = ProcessInfo.processInfo.environment
        // Lets tests and the fake matrix workflow use a throwaway config without touching the real one.
        if let override = env["P8_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base: URL
        #if os(macOS)
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        #elseif os(Windows)
            base = URL(fileURLWithPath: env["APPDATA"] ?? NSHomeDirectory(), isDirectory: true)
        #else
            if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
                base = URL(fileURLWithPath: xdg, isDirectory: true)
            } else {
                base = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config", isDirectory: true)
            }
        #endif
        return base.appendingPathComponent(appFolder, isDirectory: true)
    }

    public static var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    public static var secretsFile: URL { directory.appendingPathComponent("secrets.json") }
}
