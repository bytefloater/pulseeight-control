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
    /// A language code (see `Languages.all`) or `Languages.systemSetting` to follow the OS.
    public var language = Languages.systemSetting
    /// Whether the app looks for updates by itself. Read by the Windows updater; the macOS app leaves
    /// this to Sparkle, which remembers its own choice.
    public var checkForUpdates = true

    public init() {}

    /// Spelled out (rather than synthesized) so the decoding below can name it. The names are the property
    /// names, exactly what the synthesized keys were, so existing settings files keep loading.
    enum CodingKeys: String, CodingKey {
        case matrix, appearance, highlightGrid, showStatusBar, language, checkForUpdates
    }

    /// Each field decodes on its own: a value this version doesn't understand (a newer version's new
    /// appearance, a hand-edited setting of the wrong type) falls back to that field's default instead of
    /// discarding the whole file, which would lose the matrix's host.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matrix = Self.lenient(c, .matrix) ?? MatrixConfig()
        appearance = Self.lenient(c, .appearance) ?? .system
        highlightGrid = Self.lenient(c, .highlightGrid) ?? true
        showStatusBar = Self.lenient(c, .showStatusBar) ?? true
        language = Self.lenient(c, .language) ?? Languages.systemSetting
        checkForUpdates = Self.lenient(c, .checkForUpdates) ?? true
    }

    private static func lenient<T: Decodable>(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> T? {
        (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
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
