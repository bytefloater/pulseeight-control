import Foundation

/// Where a matrix on this network was found.
public struct DiscoveredMatrix: Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Finds the matrix on the local network the way gotomymatrix.com does.
///
/// Each matrix reports its LAN address to Pulse-Eight's service (the monitoring LED goes solid green
/// once it has). Asking the service for its front page from the same public address answers with a
/// redirect to that LAN address when it knows of a matrix there, and with an ordinary 200 "no matrix
/// found" page when it doesn't. The page's own script is only theme code: the matching is server-side.
public enum MatrixDiscovery {
    public static let defaultService = URL(string: "https://gotomymatrix.com/")!

    /// The matrix the service points this network at, or nil if it knows of none.
    ///
    /// Throws `MatrixError.connection` when the service can't be reached and `MatrixError.api` when it
    /// answers with something this doesn't understand, including a redirect to anywhere other than a
    /// private-network address: the answer comes from the internet, and the app goes on to send the
    /// admin password to whatever it names.
    public static func find(
        using transport: HTTPTransport, service: URL = defaultService
    ) async throws -> DiscoveredMatrix? {
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: .get, url: service, followRedirects: false))
        } catch let error as TransportError {
            throw MatrixError.connection("Couldn't reach \(service.host ?? "the discovery service"): \(error.description)")
        }

        switch response.status {
        case 200:
            return nil
        case 301, 302, 303, 307, 308:
            guard let location = response.location, !location.isEmpty else {
                throw MatrixError.api("The discovery service redirected without saying where")
            }
            return try matrix(fromLocation: location, relativeTo: service)
        default:
            throw MatrixError.api("The discovery service answered with status \(response.status)")
        }
    }

    /// The matrix a redirect's `Location` names, if it names a host on a private network.
    static func matrix(fromLocation location: String, relativeTo service: URL) throws -> DiscoveredMatrix {
        guard let url = URL(string: location, relativeTo: service)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { throw MatrixError.api("The discovery service sent an address that isn't a web address: \(location)") }
        guard isLocalNetworkHost(host) else {
            throw MatrixError.api("The discovery service sent \(host), which isn't on the local network")
        }
        return DiscoveredMatrix(host: host, port: url.port ?? (scheme == "https" ? 443 : 80))
    }

    /// A private, link-local or loopback IPv4 literal, or a `.local` name.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        if host.lowercased().hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
