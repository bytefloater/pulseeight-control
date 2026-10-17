import Foundation
import Testing
@testable import PulseEightKit

/// Decodes every file under `Fixtures/Real` (committed captures from a real matrix; see its README) and,
/// when `P8_REAL_FIXTURES` names another folder, that one too. With no files there is nothing to check.
@Suite struct RealFixtureTests {
    struct Fixture: Sendable, CustomTestStringConvertible {
        var url: URL
        var testDescription: String { url.lastPathComponent }
    }

    static let fixtures: [Fixture] = {
        var folders: [URL] = []
        if let resources = Bundle.module.resourceURL {
            folders.append(resources.appendingPathComponent("Fixtures/Real", isDirectory: true))
        }
        if let extra = ProcessInfo.processInfo.environment["P8_REAL_FIXTURES"], !extra.isEmpty {
            folders.append(URL(fileURLWithPath: extra, isDirectory: true))
        }
        return folders.flatMap { folder -> [Fixture] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".json") }.sorted().map { Fixture(url: folder.appendingPathComponent($0)) }
        }
    }()

    @Test(arguments: fixtures) func decodesWhatTheDeviceSent(fixture: Fixture) throws {
        let data = try Data(contentsOf: fixture.url)
        let name = fixture.url.deletingPathExtension().lastPathComponent
        let decoder = JSONDecoder()

        let envelope = try decoder.decode(ResultEnvelope.self, from: data)
        #expect(envelope.result != false, "\(name): the device reported Result=false")

        switch name {
        case "system-details":
            _ = try decoder.decode(SystemDetails.self, from: data)
        case "system-features":
            _ = try decoder.decode(SystemFeatures.self, from: data)
        case "port-list":
            let list = try decoder.decode(PortListResponse.self, from: data)
            #expect(!list.ports.isEmpty)
        case let name where name.hasPrefix("port-details-input-"):
            let details = try decoder.decode(InputPortDetails.self, from: data)
            #expect(details.base.mode == .input)
            #expect(name == "port-details-input-\(details.base.bay)", "file name should carry the port's bay")
        case let name where name.hasPrefix("port-details-output-"):
            let details = try decoder.decode(OutputPortDetails.self, from: data)
            #expect(details.base.mode == .output)
            #expect(name == "port-details-output-\(details.base.bay)", "file name should carry the port's bay")
        default:
            Issue.record("Unrecognised fixture file \(name).json; see Fixtures/Real/README.md for the names")
        }
    }

    /// The list and the per-port details come from different requests; they must describe the same ports.
    @Test func portDetailsAgreeWithThePortList() throws {
        func load(_ name: String) -> Data? {
            Self.fixtures.first { $0.url.lastPathComponent == name }.flatMap { try? Data(contentsOf: $0.url) }
        }
        guard let listData = load("port-list.json") else { return } // nothing captured
        let ports = try JSONDecoder().decode(PortListResponse.self, from: listData).ports

        for port in ports {
            let kind = port.mode.rawValue.lowercased()
            guard let data = load("port-details-\(kind)-\(port.bay).json") else { continue }
            let base: BasePortDetails
            if port.mode == .input {
                base = try JSONDecoder().decode(InputPortDetails.self, from: data).base
            } else {
                base = try JSONDecoder().decode(OutputPortDetails.self, from: data).base
            }
            #expect(base.name == port.name, "\(kind) \(port.bay): name differs between list and details")
            #expect(base.status == port.status, "\(kind) \(port.bay): status differs between list and details")
        }
    }
}
