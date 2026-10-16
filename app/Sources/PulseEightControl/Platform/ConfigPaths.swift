import Foundation

/// Per-OS location for settings. The admin password is not stored here (see `SecretStore`).
enum ConfigPaths {
    static let appFolder = "PulseEightControl"

    static var directory: URL {
        let env = ProcessInfo.processInfo.environment
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
        // Lets tests and the fake matrix workflow use a throwaway config without touching the real one.
        if let override = env["P8_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return base.appendingPathComponent(appFolder, isDirectory: true)
    }

    static var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    static var secretsFile: URL { directory.appendingPathComponent("secrets.json") }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
