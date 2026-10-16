import Foundation

/// Collapses the Python side's PulseEightConnectionError / PulseEightAPIError /
/// Pulse8AdminError plus main.py's 409 "not configured" and 404 cases.
public enum MatrixError: Error, Sendable, Equatable, LocalizedError {
    /// Couldn't reach the matrix at all (network down, timeout, refused).
    case connection(String)
    /// The matrix answered but with an error or an unexpected body.
    case api(String)
    /// An admin-gated call failed, or the admin password is missing/wrong.
    case admin(String)
    /// No host configured yet.
    case notConfigured
    case portNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .connection(let message), .api(let message), .admin(let message): return message
        case .notConfigured: return "Matrix is not configured"
        case .portNotFound(let message): return message
        }
    }
}
