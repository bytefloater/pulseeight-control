import Foundation
import Testing
@testable import PulseEightCore

/// A throwaway folder for one test.
private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("p8-secrets-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

#if !os(Windows)
private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
#endif

@Suite struct FileSecretStoreTests {
    @Test func storesAndReadsBack() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSecretStore(url: folder.appendingPathComponent("secrets.json"))

        #expect(try store.secret(for: "admin") == nil)
        try store.setSecret("hunter2", for: "admin")
        #expect(try store.secret(for: "admin") == "hunter2")
        try store.setSecret("changed", for: "admin")
        #expect(try store.secret(for: "admin") == "changed")
    }

    @Test func emptyOrNilRemovesTheSecret() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSecretStore(url: folder.appendingPathComponent("secrets.json"))

        try store.setSecret("hunter2", for: "admin")
        try store.setSecret("", for: "admin")
        #expect(try store.secret(for: "admin") == nil)

        try store.setSecret("again", for: "admin")
        try store.setSecret(nil, for: "admin")
        #expect(try store.secret(for: "admin") == nil)
    }

    @Test func accountsAreIndependent() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSecretStore(url: folder.appendingPathComponent("secrets.json"))

        try store.setSecret("one", for: "a")
        try store.setSecret("two", for: "b")
        try store.setSecret(nil, for: "a")
        #expect(try store.secret(for: "a") == nil)
        #expect(try store.secret(for: "b") == "two")
    }

    @Test func awkwardPasswordsSurviveTheRoundTrip() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSecretStore(url: folder.appendingPathComponent("secrets.json"))

        for password in ["pässwörd", "quo\"te\\back", "日本語🔐", "  spaces  ", "line\nbreak"] {
            try store.setSecret(password, for: "admin")
            #expect(try store.secret(for: "admin") == password)
        }
    }

    @Test func createsMissingFolders() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSecretStore(url: folder.appendingPathComponent("a/b/secrets.json"))

        try store.setSecret("x", for: "admin")
        #expect(try store.secret(for: "admin") == "x")
    }

    @Test func aCorruptFileReadsAsEmptyAndCanBeRewritten() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("secrets.json")
        try Data("{ this is not json".utf8).write(to: url)
        let store = FileSecretStore(url: url)

        #expect(try store.secret(for: "admin") == nil)
        try store.setSecret("fresh", for: "admin")
        #expect(try store.secret(for: "admin") == "fresh")
    }

    @Test func leavesNoTemporaryFilesBehind() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSecretStore(url: folder.appendingPathComponent("secrets.json"))

        for i in 0..<5 { try store.setSecret("v\(i)", for: "admin") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["secrets.json"])
    }

    #if !os(Windows)
    @Test func theFileIsReadableOnlyByItsOwner() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("secrets.json")
        let store = FileSecretStore(url: url)

        try store.setSecret("hunter2", for: "admin")
        #expect(try permissions(of: url) == 0o600)
        try store.setSecret("changed", for: "admin")
        #expect(try permissions(of: url) == 0o600)
    }

    /// An existing file with looser permissions (an older version, a copy) must not keep them.
    @Test func tightensAnExistingLooseFile() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("secrets.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try FileSecretStore(url: url).setSecret("hunter2", for: "admin")
        #expect(try permissions(of: url) == 0o600)
    }
    #endif
}

#if canImport(Security)
/// The real keychain, under a service name of its own so the user's real item is never touched. Skipped when
/// the keychain can't be used (a locked or missing keychain, for example on a headless machine).
@Suite struct KeychainSecretStoreTests {
    static let usable: Bool = {
        let probe = KeychainSecretStore(service: "com.pulseeight.control.tests.probe.\(UUID().uuidString)")
        do {
            try probe.setSecret("probe", for: "probe")
            let works = try probe.secret(for: "probe") == "probe"
            try probe.setSecret(nil, for: "probe")
            return works
        } catch {
            return false
        }
    }()

    @Test(.enabled(if: usable, "the keychain isn't available here"))
    func storesUpdatesAndRemoves() throws {
        let store = KeychainSecretStore(service: "com.pulseeight.control.tests.\(UUID().uuidString)")
        defer { try? store.setSecret(nil, for: "admin") }

        #expect(try store.secret(for: "admin") == nil)
        try store.setSecret("hunter2", for: "admin")
        #expect(try store.secret(for: "admin") == "hunter2")
        try store.setSecret("changed", for: "admin")
        #expect(try store.secret(for: "admin") == "changed")
        try store.setSecret("", for: "admin")
        #expect(try store.secret(for: "admin") == nil)
    }

    @Test(.enabled(if: usable, "the keychain isn't available here"))
    func servicesAreIsolatedFromEachOther() throws {
        let a = KeychainSecretStore(service: "com.pulseeight.control.tests.\(UUID().uuidString)")
        let b = KeychainSecretStore(service: "com.pulseeight.control.tests.\(UUID().uuidString)")
        defer { try? a.setSecret(nil, for: "admin"); try? b.setSecret(nil, for: "admin") }

        try a.setSecret("only-a", for: "admin")
        #expect(try b.secret(for: "admin") == nil)
    }
}
#endif
