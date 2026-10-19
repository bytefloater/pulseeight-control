import Foundation
import Testing
@testable import PulseEightKit

@Suite struct MatrixDiscoveryTests {
    func redirect(to location: String?, status: Int = 302) -> MockTransport {
        MockTransport { _ in .success(HTTPResponse(status: status, body: Data(), location: location)) }
    }

    @Test func redirectToALANAddressIsTheMatrix() async throws {
        let transport = redirect(to: "http://192.168.1.50/")
        let found = try await MatrixDiscovery.find(using: transport)
        #expect(found == DiscoveredMatrix(host: "192.168.1.50", port: 80))

        let request = try #require(transport.requests.first)
        #expect(request.url == MatrixDiscovery.defaultService)
        #expect(request.followRedirects == false)
    }

    @Test func portAndSchemeInTheRedirectAreKept() async throws {
        #expect(try await MatrixDiscovery.find(using: redirect(to: "http://10.0.0.7:8080/Home")) == DiscoveredMatrix(host: "10.0.0.7", port: 8080))
        #expect(try await MatrixDiscovery.find(using: redirect(to: "https://10.0.0.7/", status: 307)) == DiscoveredMatrix(host: "10.0.0.7", port: 443))
    }

    @Test func theNoMatrixPageMeansNothingWasFound() async throws {
        let transport = MockTransport { _ in MockTransport.reply("<html>Sorry no matrix was found</html>") }
        #expect(try await MatrixDiscovery.find(using: transport) == nil)
    }

    @Test(arguments: [
        "http://evil.example.com/",    // somewhere on the internet
        "http://8.8.8.8/",             // a public address
        "http://172.32.0.1/",          // just outside 172.16/12
        "http://192.168.1.50.evil.com/", // looks local, isn't
        "/Home",                       // relative: resolves to the service itself
        "ftp://192.168.1.50/",
    ])
    func aRedirectOffTheLocalNetworkIsRefused(location: String) async {
        await #expect(throws: MatrixError.self) {
            _ = try await MatrixDiscovery.find(using: redirect(to: location))
        }
    }

    @Test func aRedirectWithoutALocationIsAnError() async {
        await #expect(throws: MatrixError.api("The discovery service redirected without saying where")) {
            _ = try await MatrixDiscovery.find(using: redirect(to: nil))
        }
    }

    @Test func otherStatusesAreErrors() async {
        let transport = MockTransport { _ in MockTransport.reply("", status: 500) }
        await #expect(throws: MatrixError.api("The discovery service answered with status 500")) {
            _ = try await MatrixDiscovery.find(using: transport)
        }
    }

    @Test func anUnreachableServiceIsAConnectionError() async {
        let transport = MockTransport { _ in .failure(TransportError("offline")) }
        await #expect(throws: MatrixError.connection("Couldn't reach gotomymatrix.com: offline")) {
            _ = try await MatrixDiscovery.find(using: transport)
        }
    }

    @Test func localHostClassification() {
        for host in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.0.1", "169.254.1.1", "127.0.0.1", "matrix.local"] {
            #expect(MatrixDiscovery.isLocalNetworkHost(host), "\(host)")
        }
        for host in ["172.15.0.1", "172.32.0.1", "11.0.0.1", "192.169.0.1", "256.1.1.1", "1.2.3", "gotomymatrix.com", ""] {
            #expect(!MatrixDiscovery.isLocalNetworkHost(host), "\(host)")
        }
    }
}
