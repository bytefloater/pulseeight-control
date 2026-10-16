import Foundation
import PulseEightKit

enum Appearance: String, Codable, CaseIterable, CustomStringConvertible {
    case system, light, dark

    var description: String { rawValue.capitalized }
}

/// Everything persisted in settings.json. `matrix` uses the same keys as the old
/// backend/config.json, minus `admin_password`.
struct AppSettings: Codable, Equatable {
    var matrix = MatrixConfig()
    var appearance: Appearance = .system
    /// Row/column highlight under the pointer in the routing grid.
    var highlightGrid = true
    var showStatusBar = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matrix = try c.decodeIfPresent(MatrixConfig.self, forKey: .matrix) ?? MatrixConfig()
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        highlightGrid = try c.decodeIfPresent(Bool.self, forKey: .highlightGrid) ?? true
        showStatusBar = try c.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? true
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: ConfigPaths.settingsFile),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() throws {
        try ConfigPaths.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: ConfigPaths.settingsFile, options: .atomic)
    }
}
