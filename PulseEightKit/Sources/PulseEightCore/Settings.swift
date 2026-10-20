import Foundation
import PulseEightKit

public enum Appearance: String, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case system, light, dark

    public var description: String { rawValue.capitalized }
}

/// One matrix the app can connect to: its own address, timings and (in the secret store, under
/// `AppCore.adminAccount(for:)`) admin password, plus a name to tell it apart.
public struct MatrixProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// What the person calls it. May be empty, in which case `displayName` is its address.
    public var name: String
    public var config: MatrixConfig

    public init(id: UUID = UUID(), name: String = "", config: MatrixConfig = MatrixConfig()) {
        self.id = id
        self.name = name
        self.config = config
    }

    /// The name, or the address when there is no name.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }

    /// Host, plus the port when it isn't 80. "Matrix" before there is a host.
    public var address: String {
        guard let host = config.host, !host.isEmpty else { return "Matrix" }
        return config.port == 80 ? host : "\(host):\(config.port)"
    }

    enum CodingKeys: String, CodingKey { case id, name }

    /// The connection fields sit beside `id` and `name` (not under a key of their own), with the keys
    /// `MatrixConfig` has always used, so a profile reads like the single matrix the file used to hold.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        config = try MatrixConfig(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try config.encode(to: encoder)
    }
}

/// Everything persisted in settings.json.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Every matrix that has been added, in the order they were added.
    public var matrices: [MatrixProfile] = []
    /// The one being shown. When it names nothing (or nil) the first matrix is the selected one.
    public var selectedMatrixID: UUID?
    public var appearance: Appearance = .system
    /// Row/column highlight under the pointer in the routing grid.
    public var highlightGrid = true
    public var showStatusBar = true
    /// A language code (see `Languages.all`) or `Languages.systemSetting` to follow the OS.
    public var language = Languages.systemSetting
    /// Whether the app looks for updates by itself. Read by the Windows updater; the macOS app leaves
    /// this to Sparkle, which remembers its own choice.
    public var checkForUpdates = true
    /// Whether updates may be release candidates and betas, as well as releases. nil (the default) follows the installed build:
    /// a pre-release build keeps getting pre-releases until the person says otherwise, a release build only releases.
    public var updatePrereleases: Bool?

    public init() {}

    public var selectedMatrix: MatrixProfile? {
        matrices.first { $0.id == selectedMatrixID } ?? matrices.first
    }

    /// The selected matrix's connection settings (defaults when there is none). Setting it changes the
    /// selected matrix, or adds one when there is none yet.
    public var matrix: MatrixConfig {
        get { selectedMatrix?.config ?? MatrixConfig() }
        set {
            if let index = matrices.firstIndex(where: { $0.id == selectedMatrix?.id }) {
                matrices[index].config = newValue
            } else {
                let profile = MatrixProfile(config: newValue)
                matrices = [profile]
                selectedMatrixID = profile.id
            }
        }
    }

    /// The property names, except `matrix`: the single matrix older versions kept there is read (see
    /// `init(from:)`) but no longer written.
    enum CodingKeys: String, CodingKey {
        case matrices, selectedMatrix, matrix, appearance, highlightGrid, showStatusBar, language, checkForUpdates, updatePrereleases
    }

    /// Each field decodes on its own: a value this version doesn't understand (a newer version's new
    /// appearance, a hand-edited setting of the wrong type) falls back to that field's default instead of
    /// discarding the whole file, which would lose the matrices' hosts.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list: [Lossy<MatrixProfile>] = Self.lenient(c, .matrices) {
            matrices = list.compactMap(\.value)
        } else if let old: MatrixConfig = Self.lenient(c, .matrix), old.host?.isEmpty == false {
            // A file from before there could be several: its one matrix becomes the first.
            matrices = [MatrixProfile(name: old.host ?? "", config: old)]
        }
        selectedMatrixID = Self.lenient(c, .selectedMatrix) ?? matrices.first?.id
        appearance = Self.lenient(c, .appearance) ?? .system
        highlightGrid = Self.lenient(c, .highlightGrid) ?? true
        showStatusBar = Self.lenient(c, .showStatusBar) ?? true
        language = Self.lenient(c, .language) ?? Languages.systemSetting
        checkForUpdates = Self.lenient(c, .checkForUpdates) ?? true
        updatePrereleases = Self.lenient(c, .updatePrereleases)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(matrices, forKey: .matrices)
        try c.encodeIfPresent(selectedMatrix?.id, forKey: .selectedMatrix)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(highlightGrid, forKey: .highlightGrid)
        try c.encode(showStatusBar, forKey: .showStatusBar)
        try c.encode(language, forKey: .language)
        try c.encode(checkForUpdates, forKey: .checkForUpdates)
        try c.encodeIfPresent(updatePrereleases, forKey: .updatePrereleases)
    }

    private static func lenient<T: Decodable>(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> T? {
        (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Whether a settings file holds the single matrix of older versions, which `AppCore` then rewrites in
    /// the current form and moves the admin password along with.
    static func isLegacyFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["matrices"] == nil && object["matrix"] != nil
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

/// An array element that decodes to nil instead of failing, so one bad entry doesn't take the list with it.
private struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
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
