import Network
import Testing
@testable import PulseEightControl

@MainActor
@Suite struct LocalNetworkPermissionTests {
    @Test func aReadyBrowserMeansTheAppIsAllowed() {
        #expect(LocalNetworkPermission.answer(for: .ready) == .granted)
    }

    @Test func aPolicyDeniedBrowserMeansTheAppWasRefused() {
        let denied = NWError.dns(-65570) // kDNSServiceErr_PolicyDenied
        #expect(LocalNetworkPermission.answer(for: .waiting(denied)) == .denied)
        #expect(LocalNetworkPermission.answer(for: .failed(denied)) == .denied)
    }

    @Test func otherStatesSayNothingYet() {
        #expect(LocalNetworkPermission.answer(for: .setup) == nil)
        #expect(LocalNetworkPermission.answer(for: .cancelled) == nil)
        #expect(LocalNetworkPermission.answer(for: .waiting(.dns(-65537))) == nil, "some other DNS error isn't a refusal")
        #expect(LocalNetworkPermission.answer(for: .failed(.posix(.ECONNREFUSED))) == nil)
    }

    @Test func aDisabledPermissionNeverAsksAndNeverChanges() {
        let permission = LocalNetworkPermission.disabled
        permission.check()
        #expect(permission.state == .unknown)
    }

    @Test(arguments: ["127.0.0.1", "127.1.2.3", "localhost", "LOCALHOST", " localhost ", "::1", "[::1]"])
    func matricesOnThisMacNeedNoPermission(host: String) {
        #expect(AppModel.isOnThisMac(host))
    }

    @Test(arguments: ["172.16.4.2", "192.168.1.150", "matrix.local", "10.0.0.1", "127example.com"])
    func matricesOnTheNetworkDo(host: String) {
        #expect(!AppModel.isOnThisMac(host))
    }
}
