import Foundation
import PulseEightFakeMatrix

// Stand-in for a Pulse-Eight NeoMatrix, for developing the apps without hardware.
//
//     p8fake --port 8080 --password secret
//     p8ctl --host 127.0.0.1 --port 8080 ports

let usage = """
Usage: p8fake [options]

  --host HOST        address to listen on (default 127.0.0.1; 0.0.0.0 for the whole network)
  --port PORT        port to listen on (default 8080)
  --password TEXT    admin password; omit to allow admin calls without logging in
  --bays N           inputs and outputs per side (default 8; 8 or 16 on real hardware)
  --latency SECONDS  delay every reply, to see pending states in a UI (default 0)
  --quiet            don't log each request
  --help             show this text
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

let quiet = takeFlag("--quiet")
let host = takeOption("--host") ?? "127.0.0.1"
let password = takeOption("--password")
guard let port = UInt16(takeOption("--port") ?? "8080") else { fail("--port must be a number from 0 to 65535") }
guard let bays = Int(takeOption("--bays") ?? "8"), bays >= 1 else { fail("--bays must be a positive number") }
guard let latency = Double(takeOption("--latency") ?? "0"), latency >= 0 else { fail("--latency must be a number of seconds") }
if let unknown = arguments.first { fail("Unknown argument \(unknown)\n\n\(usage)") }

let matrix = FakeMatrix(.init(bays: bays, password: password, latency: latency))
func output(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func makeLogger(quiet: Bool) -> (@Sendable (String) -> Void)? {
    if quiet { return nil }
    return { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
}

let server = FakeMatrixServer(matrix: matrix, host: host, port: port, log: makeLogger(quiet: quiet))

do {
    try server.start()
} catch {
    fail("\(error)")
}

output("Fake NeoMatrix on http://\(host):\(server.port) (admin password: \(password ?? "none"))")

// The server runs on its own threads; keep the process alive until it is killed.
while true { Thread.sleep(forTimeInterval: 3600) }
