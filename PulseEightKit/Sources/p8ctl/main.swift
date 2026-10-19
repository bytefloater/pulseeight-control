import Foundation
import PulseEightCore
import PulseEightKit

// Small CLI over PulseEightKit. Stands in for the old POST /api/route/by-name automation
// endpoint and doubles as a way to verify the device layer without any UI.

let usage = """
Usage: p8ctl [--host HOST] [--port PORT] [--timeout SECONDS] <command>

Host defaults to $P8_HOST.

Commands:
  discover [--service URL]  Ask gotomymatrix.com (or URL) which matrix is on this network; needs no host
  status                    Show model, firmware and connection info
  health                    Show the matrix's own health report: power, temperatures, modules, uptime
  ports                     List inputs and outputs and what is routed where
  route <input> <output>    Route an input to an output, by port name (case-insensitive)
  set <input-bay> <output-bay>
                            Route by bay number
  capture <dir> [--no-redact]
                            Save the raw JSON of every endpoint into <dir>, as test fixtures.
                            Serial numbers and MAC addresses are redacted unless --no-redact.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var host = ProcessInfo.processInfo.environment["P8_HOST"]
var port = 80
var timeout = 10

func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

if let value = takeOption("--host") { host = value }
func takeInt(_ name: String) -> Int? {
    guard let value = takeOption(name) else { return nil }
    guard let number = Int(value) else { fail("Invalid \(name) '\(value)'") }
    return number
}

func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

let serviceOption = takeOption("--service")
let redact = !takeFlag("--no-redact")
if let value = takeInt("--port") { port = value }
if let value = takeInt("--timeout") { timeout = value }

guard let command = arguments.first else { fail(usage, code: 2) }
if command == "-h" || command == "--help" || command == "help" {
    print(usage)
    exit(0)
}
if command == "discover" {
    do {
        let transport = makeDefaultTransport(timeout: TimeInterval(timeout))
        let service = serviceOption.flatMap { URL(string: $0) } ?? MatrixDiscovery.defaultService
        if let found = try await MatrixDiscovery.find(using: transport, service: service) {
            print("\(found.host):\(found.port)")
        } else {
            fail("No matrix found on this network (is the monitoring LED solid green?)", code: 3)
        }
    } catch {
        fail("Error: \(error.localizedDescription)")
    }
    exit(0)
}
guard let host, !host.isEmpty else { fail("No host: pass --host or set P8_HOST") }

let client: MatrixClient
do {
    client = try MatrixClient(host: host, port: port, transport: makeDefaultTransport(timeout: TimeInterval(timeout)))
} catch {
    fail("\(error.localizedDescription)")
}

func printPorts(_ ports: [MatrixPort]) {
    let inputs = ports.filter { $0.mode == .input }.sorted { $0.bay < $1.bay }
    let outputs = ports.filter { $0.mode == .output }.sorted { $0.bay < $1.bay }
    func name(ofInput bay: Int?) -> String {
        guard let bay else { return "-" }
        return inputs.first { $0.bay == bay }?.name ?? "input \(bay)"
    }
    print("Inputs")
    for port in inputs {
        print("  \(port.bay)  \(port.name)  [\(port.status.label)]")
    }
    print("Outputs")
    for port in outputs {
        print("  \(port.bay)  \(port.name)  [\(port.status.label)]  <- \(name(ofInput: port.receiveFrom))")
    }
}

do {
    switch command {
    case "status":
        let details = try await client.systemDetails()
        let ports = try await client.ports()
        print("Model:    \(details.model)")
        print("Version:  \(details.version)")
        print("Serial:   \(details.serial)")
        print("Status:   \(details.statusMessage)")
        print("Ports:    \(ports.filter { $0.mode == .input }.count) in, \(ports.filter { $0.mode == .output }.count) out")
    case "health":
        let health = try await client.systemHealth()
        let strings = Strings(language: .english)
        for row in Presentation.healthRows(health, strings) { print("\(row.label): \(row.value)") }
    case "ports":
        printPorts(try await client.ports())
    case "route":
        guard arguments.count == 3 else { fail("route needs <input> <output>", code: 2) }
        let result = try await client.route(inputNamed: arguments[1], outputNamed: arguments[2])
        print(result.message)
    case "set":
        guard arguments.count == 3, let input = Int(arguments[1]), let output = Int(arguments[2]) else {
            fail("set needs <input-bay> <output-bay>", code: 2)
        }
        let result = try await client.setPort(input: input, output: output)
        print(result.message)
    case "capture":
        guard arguments.count == 2 else { fail("capture needs <dir>", code: 2) }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await DeviceCapture.capture(from: client, redact: redact)
        for file in result.files {
            try file.data.write(to: directory.appendingPathComponent(file.name))
            print("wrote \(file.name)")
        }
        for note in result.skipped { print("skipped \(note)") }
        if redact { print("Serial numbers and MAC addresses were redacted. Port names were not: check them before committing.") }
    default:
        fail("Unknown command '\(command)'\n\n\(usage)", code: 2)
    }
} catch {
    fail("Error: \(error.localizedDescription)")
}
