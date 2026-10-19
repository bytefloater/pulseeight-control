import Foundation
@testable import PulseEightKit

/// Records requests and replies from a closure. Stands in for the network.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) -> Result<HTTPResponse, TransportError>

    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Replies 200 with `Fixtures` for the matrix's read endpoints, `{"Result":true}` for admin calls.
    static func device() -> MockTransport {
        MockTransport { request in
            let path = request.url.path
            let body: String
            switch path {
            case "/Port/List": body = Fixtures.portList
            case "/System/Details": body = Fixtures.systemDetails
            case "/system/features": body = Fixtures.systemFeatures
            case "/System/Health": body = Fixtures.systemHealth
            case "/Monitoring/Settings": body = Fixtures.monitoringSettings
            case "/Port/Details/Input/0": body = Fixtures.inputDetails
            case "/Port/Details/Input/1": body = Fixtures.inputDetails
            case "/Port/Details/Output/0": body = Fixtures.outputDetails
            case "/Port/Details/Output/1": body = Fixtures.outputDetails
            default:
                if path.hasPrefix("/Port/Set/") { body = #"{"Result":true,"Message":"Changed"}"# }
                else { body = #"{"Result":true}"# }
            }
            return .success(HTTPResponse(status: 200, body: Data(body.utf8)))
        }
    }

    /// This mock's reply to `request`, for tests that override just a few paths and delegate the rest.
    func handlerResponse(for request: HTTPRequest) -> Result<HTTPResponse, TransportError> {
        lock.lock(); defer { lock.unlock() }
        return handler(request)
    }

    static func reply(_ body: String, status: Int = 200) -> Result<HTTPResponse, TransportError> {
        .success(HTTPResponse(status: status, body: Data(body.utf8)))
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// "METHOD /path" for each request so far, ignoring the cache-busting query.
    var summary: [String] {
        // URL.path drops a trailing slash, which matters for /Port/SetName/{Mode}/{Bay}/.
        requests.map { "\($0.method.rawValue) \(URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.path ?? "")" }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch record(request)(request) {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    // Synchronous so the lock is never held across (or taken from) an async context.
    private func record(_ request: HTTPRequest) -> Handler {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return handler
    }
}

/// Holds every request to one host open until the test releases it, so a test can change the store's
/// configuration while a poll is in flight. Requests to any other host are answered at once.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let inner: HTTPTransport
    private let gatedHost: String
    private let lock = NSLock()
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0

    init(gatedHost: String, inner: HTTPTransport) {
        self.gatedHost = gatedHost
        self.inner = inner
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.host == gatedHost { await hold() }
        return try await inner.send(request)
    }

    private func hold() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrivals += 1
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Requests to the gated host that have arrived so far.
    var arrived: Int {
        lock.lock(); defer { lock.unlock() }
        return arrivals
    }

    /// Lets every held request, and all later ones, through.
    func release() {
        lock.lock()
        released = true
        let toResume = waiting
        waiting = []
        lock.unlock()
        toResume.forEach { $0.resume() }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.date = date }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}

/// Collects published states and lets a test wait for a condition.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [MatrixState] = []

    func record(_ state: MatrixState) {
        lock.lock(); defer { lock.unlock() }
        states.append(state)
    }

    var latest: MatrixState? {
        lock.lock(); defer { lock.unlock() }
        return states.last
    }

    /// Every state published so far, oldest first.
    var all: [MatrixState] {
        lock.lock(); defer { lock.unlock() }
        return states
    }

    func wait(timeout: TimeInterval = 5, until condition: (MatrixState) -> Bool) async -> MatrixState? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let latest, condition(latest) { return latest }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}

/// Synthetic payloads built from the field names in pulse_eight_matrix_client/models.py.
/// TODO(M0): replace with responses captured from the real matrix.
enum Fixtures {
    static let portList = #"""
    {"Result":true,"Ports":[
      {"Bay":0,"Mode":"Input","Type":"HDMI IN","Status":0,"Name":"Sky"},
      {"Bay":1,"Mode":"Input","Type":"HDMI IN","Status":3,"Name":"Apple TV"},
      {"Bay":0,"Mode":"Output","Type":"HDBT OUT","Status":0,"Name":"Lounge TV","ReceiveFrom":0},
      {"Bay":1,"Mode":"Output","Type":"HDBT OUT","Status":2,"Name":"Bedroom TV","ReceiveFrom":1,"rcType":2}
    ]}
    """#

    static let systemDetails = #"""
    {"Result":true,"Model":"NeoMatrix","Version":"1.2.3","Serial":"ABC123","MAC":"00:11:22:33:44:55",
     "VID":"1234","BoardRev":2,"Revision":{"Main":1,"Top":2,"Ir":3},"Locale":"en-GB",
     "StatusMessage":"OK","Status":0}
    """#

    /// BacklightLED / StatusLED / CEC use the device's all-caps spelling, which the Python
    /// library silently failed to read.
    /// What a real NeoMatrix (firmware 3.10.6) sends for the cloud link.
    static let monitoringSettings = #"""
    {"Result":true,"LastContact":1213,"InstallerId":1924,"AutoUpdates":true,"UpdateAvailable":false}
    """#

    /// What a real NeoMatrix sends (one power supply, five sensors).
    static let systemHealth = #"""
    {"Result":true,"psu":[{"name":"3.3V","ok":true,"value":3.396945},{"name":"12V","ok":true,"value":12.256533},{"name":"1V top","ok":true,"value":0.000000}],"Locale":"EN_UK","StatusMessage":"Healthy","Status":0,"Temperature0":32,"Temperature1":31,"Temperature2":36,"PSU1Message":"Present & Healthy","PSU1":0,"InputModulesMessage":"All Present & Healthy","InputModules":0,"OutputModulesMessage":"All Present & Healthy","OutputModules":0,"SysUpdState":6,"Uptime":899}
    """#

    static let systemFeatures = #"""
    {"Result":true,"UpdInterval":5,"CEC":1,"CEC_Switching":false,"CEC_Logging":0,"CEC_Usage":1,
     "PDU":false,"Sky":true,"HDBaseT":true,"HdbtUpgrade":true,"MxRemote":false,
     "Video":{"Scrambling":true,"Input":{"Bays":8},"Output":{"Bays":8}},
     "Audio":{"Routing":true,"Input":{"Bays":8},"Output":{"Bays":8}},
     "BacklightLED":"High","StatusLED":"On"}
    """#

    static let inputDetails = #"""
    {"Result":true,"Bay":0,"Mode":"Input","Type":"HDMI IN","Status":0,"Name":"Sky","StatusMessage":"OK",
     "HPD":1,"HasSignal":true,"VideoSignal":"3840x2160@60","Signal":"HDMI","HDCP":1,"EdidProfile":0}
    """#

    static let outputDetails = #"""
    {"Result":true,"Bay":0,"Mode":"Output","Type":"HDBT OUT","Status":0,"Name":"Lounge TV","StatusMessage":"OK",
     "ReceiveFrom":0,"POE":true,"FirmwareVersion":"1.0.0","FirmwareVersionAvailable":true,
     "OverrideEDID":{"Address":"0x50","Setting":3}}
    """#
}
