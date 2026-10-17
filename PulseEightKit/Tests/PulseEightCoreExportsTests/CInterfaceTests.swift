import Foundation
import Testing
import PulseEightCore
import PulseEightCoreExports

/// The C interface (`include/pulseeight_core.h`) driven the way the Windows app drives it. Serialized, because
/// `p8_create` reads `P8_CONFIG_DIR` and `P8_SECRET_STORE` from the process environment and each test wants its
/// own scratch settings (and never the Keychain).
@Suite(.serialized) struct CInterfaceTests {
    final class Scratch {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p8-abi-\(UUID().uuidString)", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    final class SnapshotLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        var snapshots: [String] { lock.lock(); defer { lock.unlock() }; return items }
        func add(_ json: String) { lock.lock(); items.append(json); lock.unlock() }
    }

    static let observer: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, json in
        guard let context, let json else { return }
        Unmanaged<SnapshotLog>.fromOpaque(context).takeUnretainedValue().add(String(cString: json))
    }

    private func setEnvironment(_ name: String, _ value: String) {
        #if os(Windows)
        _ = _putenv_s(name, value)
        #else
        setenv(name, value, 1)
        #endif
    }

    /// A handle over fresh scratch settings. Keep the scratch alive for the test's duration.
    func makeHandle() throws -> (handle: UnsafeMutableRawPointer, scratch: Scratch) {
        let scratch = Scratch()
        setEnvironment("P8_CONFIG_DIR", scratch.url.path)
        setEnvironment("P8_SECRET_STORE", "file")
        return (try #require(p8_create()), scratch)
    }

    func call(_ handle: UnsafeMutableRawPointer?, _ request: String?) throws -> [String: Any] {
        let reply: UnsafeMutablePointer<CChar>?
        if let request { reply = request.withCString { p8_call(handle, $0) } } else { reply = p8_call(handle, nil) }
        defer { p8_free_string(reply) }
        let text = String(cString: try #require(reply, "p8_call must always answer"))
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "reply isn't a JSON object: \(text)")
    }

    func snapshot(_ handle: UnsafeMutableRawPointer?) throws -> CoreSnapshot {
        let raw = p8_snapshot(handle)
        defer { p8_free_string(raw) }
        let text = String(cString: try #require(raw))
        return try JSONDecoder().decode(CoreSnapshot.self, from: Data(text.utf8))
    }

    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    // MARK: Basics

    @Test func theInterfaceVersionIsOne() {
        #expect(p8_abi_version() == 1)
    }

    @Test func aNewCoreWithNoSavedHostIsNotConfigured() throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }

        let snapshot = try snapshot(handle)
        #expect(snapshot.schema == 1)
        #expect(snapshot.phase == "notConfigured")
        #expect(snapshot.settings.host == nil)
        #expect(!snapshot.adminConfigured)
        #expect(snapshot.languages.contains { $0.code == "en" })
    }

    @Test func commandsChangeTheStateTheSnapshotReports() throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }

        #expect(try call(handle, #"{"cmd":"setAppearance","value":"dark"}"#)["ok"] as? Bool == true)
        #expect(try call(handle, #"{"cmd":"setHighlightGrid","on":false}"#)["ok"] as? Bool == true)
        let snapshot = try snapshot(handle)
        #expect(snapshot.settings.appearance == "dark")
        #expect(snapshot.settings.highlightGrid == false)
    }

    @Test func theUpdateCheckSettingIsACommandAndPersists() throws {
        let (first, scratch) = try makeHandle()
        #expect(try snapshot(first).settings.checkForUpdates, "on by default")

        #expect(try call(first, #"{"cmd":"setCheckForUpdates","on":false}"#)["ok"] as? Bool == true)
        #expect(try snapshot(first).settings.checkForUpdates == false)
        #expect(try call(first, #"{"cmd":"setCheckForUpdates","on":"yes"}"#)["ok"] as? Bool == false, "a non-boolean is refused")
        p8_destroy(first)

        let second = try #require(p8_create())
        defer { p8_destroy(second); _ = scratch }
        #expect(try snapshot(second).settings.checkForUpdates == false, "the choice is remembered")
    }

    @Test func settingsPersistAcrossHandles() throws {
        let (first, scratch) = try makeHandle()
        _ = try call(first, #"{"cmd":"saveSettings","host":"10.9.8.7","port":8080}"#)
        p8_destroy(first)

        // A second handle over the same folder (the environment still points at it) sees the saved host.
        let second = try #require(p8_create())
        defer { p8_destroy(second); _ = scratch }
        let snapshot = try snapshot(second)
        #expect(snapshot.settings.host == "10.9.8.7")
        #expect(snapshot.settings.port == 8080)
    }

    @Test func validationAnswersCarryTheValueOrAMessage() throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }

        let good = try call(handle, #"{"cmd":"validatePortName","name":"  Lounge  "}"#)
        #expect(good["ok"] as? Bool == true)
        #expect(good["value"] as? String == "Lounge")

        let bad = try call(handle, #"{"cmd":"validatePortName","name":"this name is far too long"}"#)
        #expect(bad["ok"] as? Bool == false)
        #expect((bad["error"] as? String)?.isEmpty == false)
    }

    // MARK: Bad input must never crash or go unanswered

    @Test func rejectsAMissingRequestAndAMissingHandle() throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }

        #expect(try call(handle, nil)["ok"] as? Bool == false)
        #expect(try call(nil, #"{"cmd":"retry"}"#)["ok"] as? Bool == false)
        #expect(p8_snapshot(nil) == nil)
    }

    @Test(arguments: ["", "{", "not json", "[]", "null", "42", #"{"cmd":42}"#, #"{"cmd":"noSuchCommand"}"#, #"{"nocmd":true}"#,
                      #"{"cmd":"route"}"#, #"{"cmd":"route","input":"a","output":1}"#, #"{"cmd":"setBacklight","level":"loud"}"#])
    func rejectsMalformedRequestsWithAMessage(request: String) throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }

        let reply = try call(handle, request)
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? String)?.isEmpty == false)
    }

    /// A field that is present but of the wrong type is refused. It used to be swapped for the default and the
    /// rest of the command carried on, saving settings (here a host) the caller never meant to save.
    @Test(arguments: [#"[1,2]"#, #"{"a":1}"#])
    func aWronglyTypedFieldIsRefusedAndNothingIsSaved(port: String) throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }

        let reply = try call(handle, #"{"cmd":"saveSettings","host":"10.1.2.3","port":\#(port)}"#)
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? String)?.contains("port") == true)
        #expect(try snapshot(handle).settings.host == nil, "a refused command must not have saved anything")

        // A missing port still takes its default, and numbers are accepted as well as text.
        #expect(try call(handle, #"{"cmd":"saveSettings","host":"10.1.2.3"}"#)["ok"] as? Bool == true)
        #expect(try snapshot(handle).settings.port == 80)
        #expect(try call(handle, #"{"cmd":"saveSettings","host":"10.1.2.3","port":8080}"#)["ok"] as? Bool == true)
        #expect(try snapshot(handle).settings.port == 8080)
    }

    @Test func invalidUTF8InARequestIsAnErrorNotACrash() throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }

        let bytes: [CChar] = [0x7B, CChar(bitPattern: 0xFF), CChar(bitPattern: 0xFE), 0x7D, 0] // {\xFF\xFE}
        let reply = bytes.withUnsafeBufferPointer { p8_call(handle, $0.baseAddress) }
        defer { p8_free_string(reply) }
        let object = try JSONSerialization.jsonObject(with: Data(String(cString: try #require(reply)).utf8)) as? [String: Any]
        #expect(object?["ok"] as? Bool == false)
    }

    @Test func nullArgumentsAreHarmless() {
        p8_destroy(nil)
        p8_free_string(nil)
        p8_set_observer(nil, nil, nil)
    }

    // MARK: Observer

    @Test func theObserverHearsChangesAndANullCallbackSilencesIt() async throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }
        let log = SnapshotLog()
        p8_set_observer(handle, Self.observer, Unmanaged.passUnretained(log).toOpaque())

        _ = try call(handle, #"{"cmd":"setAppearance","value":"dark"}"#)
        let heardIt = await waitUntil {
            log.snapshots.contains { (try? JSONDecoder().decode(CoreSnapshot.self, from: Data($0.utf8)))?.settings.appearance == "dark" }
        }
        #expect(heardIt, "the observer should be told, with a snapshot reflecting the change")

        p8_set_observer(handle, nil, nil)
        let heard = log.snapshots.count
        _ = try call(handle, #"{"cmd":"setAppearance","value":"light"}"#)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(log.snapshots.count == heard, "a cleared observer was still called")
    }

    @Test func destroyingAHandleWithAnObserverIsClean() async throws {
        let (handle, scratch) = try makeHandle()
        _ = scratch
        let log = SnapshotLog()
        p8_set_observer(handle, Self.observer, Unmanaged.passUnretained(log).toOpaque())
        _ = try call(handle, #"{"cmd":"setAppearance","value":"dark"}"#)

        p8_destroy(handle)
        let heard = log.snapshots.count
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(log.snapshots.count == heard, "an observer was called after p8_destroy")
    }

    // MARK: Threads

    /// "Functions may be called from any thread": many at once must neither crash nor corrupt a reply.
    @Test func concurrentCallsAndSnapshotsAreSafe() throws {
        let (handle, scratch) = try makeHandle()
        defer { p8_destroy(handle); _ = scratch }

        let failures = SnapshotLog()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let request = i % 2 == 0
                ? #"{"cmd":"validatePortName","name":"Port \#(i)"}"#
                : #"{"cmd":"setHighlightGrid","on":\#(i % 4 == 1)}"#
            let reply = request.withCString { p8_call(handle, $0) }
            let text = reply.map { String(cString: $0) } ?? ""
            p8_free_string(reply)
            if !text.contains("\"ok\":true") { failures.add("call \(i): \(text)") }

            let raw = p8_snapshot(handle)
            let snapshotText = raw.map { String(cString: $0) } ?? ""
            p8_free_string(raw)
            if (try? JSONDecoder().decode(CoreSnapshot.self, from: Data(snapshotText.utf8))) == nil { failures.add("snapshot \(i)") }
        }
        #expect(failures.snapshots.isEmpty, "\(failures.snapshots.prefix(3))")
    }
}
