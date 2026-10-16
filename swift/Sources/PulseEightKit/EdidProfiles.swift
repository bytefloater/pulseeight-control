import Foundation

public struct EdidProfile: Sendable, Equatable, Identifiable, Hashable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// The IDs and names aren't returned by the device anywhere; they're a fixed table baked into
/// the vendor's own admin JS (p8setup.min.js). "Clone Display N" entries (id 101 + bay) mirror a
/// connected output and are generated from the matrix's real output ports.
public enum EdidProfiles {
    static let cloneProfileBase = 101

    static let standard: [EdidProfile] = [
        EdidProfile(id: 11, name: "Dynamic (Lowest Common Denominator)"),
        EdidProfile(id: 4, name: "720p/2.0"),
        EdidProfile(id: 0, name: "1080p/2.0 (Default)"),
        EdidProfile(id: 3, name: "1080p/Dolby 5.1"),
        EdidProfile(id: 5, name: "1080p/7.1"),
        EdidProfile(id: 2, name: "Ultra HD (4k)"),
        EdidProfile(id: 6, name: "Ultra HD (4k)/7.1"),
    ]

    static let hdr: [EdidProfile] = [
        EdidProfile(id: 7, name: "HDR10/Dolby 5.1"),
        EdidProfile(id: 8, name: "HDR10/7.1"),
    ]

    /// `ports` is the live list; only outputs are used.
    public static func build(scrambling: Bool, ports: [MatrixPort]) -> [EdidProfile] {
        var profiles = standard
        if scrambling { profiles += hdr }
        for output in ports.filter({ $0.mode == .output }).sorted(by: { $0.bay < $1.bay }) {
            profiles.append(EdidProfile(id: cloneProfileBase + output.bay, name: "Clone Display \(output.bay + 1) — \(output.name)"))
        }
        return profiles
    }
}
