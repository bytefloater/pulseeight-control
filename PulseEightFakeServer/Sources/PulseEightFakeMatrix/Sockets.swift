import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The few socket calls the fake server needs, over WinSock2 on Windows and BSD sockets elsewhere.
/// Deliberately not URLSession/libdispatch/NIO: plain blocking sockets on Foundation threads.
enum Sockets {
    #if os(Windows)
    typealias Handle = SOCKET
    static let invalid = INVALID_SOCKET
    #else
    typealias Handle = Int32
    static let invalid: Int32 = -1
    #endif

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private static let startOnce: Void = {
        #if os(Windows)
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
        #else
        signal(SIGPIPE, SIG_IGN) // a client hanging up mid-reply must not kill the server
        #endif
    }()

    /// IPv4 address in network byte order. Accepts dotted quads and "localhost".
    private static func address(_ host: String) throws -> UInt32 {
        let text = host == "localhost" ? "127.0.0.1" : host
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else {
            throw Failure(description: "\"\(host)\" isn't an IPv4 address (use e.g. 127.0.0.1 or 0.0.0.0)")
        }
        return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]).bigEndian
    }

    private static func makeAddress(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        #if os(Windows)
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = try Self.address(host)
        #else
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = try Self.address(host)
        #endif
        address.sin_port = port.bigEndian
        return address
    }

    /// Binds and listens. Port 0 picks a free port; read it back with `port(of:)`.
    static func makeListener(host: String, port: UInt16) throws -> Handle {
        _ = startOnce
        var address = try makeAddress(host: host, port: port)

        #if os(Windows)
        let handle = socket(AF_INET, SOCK_STREAM, 6 /* IPPROTO_TCP */)
        #elseif canImport(Glibc)
        let handle = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard handle != invalid else { throw Failure(description: "Couldn't create a socket") }

        #if !os(Windows)
        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                #if os(Windows)
                bind(handle, generic, Int32(MemoryLayout<sockaddr_in>.size))
                #else
                bind(handle, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard bound == 0 else {
            closeHandle(handle)
            throw Failure(description: "Couldn't listen on \(host):\(port) (is the port already in use?)")
        }
        // A deep backlog: the old Python server's tiny one made clients see connection resets.
        guard listen(handle, 128) == 0 else {
            closeHandle(handle)
            throw Failure(description: "Couldn't start listening on \(host):\(port)")
        }
        return handle
    }

    /// The port a listening socket is bound to.
    static func port(of handle: Handle) -> UInt16 {
        var address = sockaddr_in()
        #if os(Windows)
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Blocks for the next client; returns `invalid` once the listener is closed.
    static func acceptClient(_ listener: Handle) -> Handle {
        #if os(Windows)
        accept(listener, nil, nil)
        #else
        accept(listener, nil, nil)
        #endif
    }

    /// Bytes received, 0 when the peer closed, negative on error.
    static func receive(_ handle: Handle, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        #if os(Windows)
        Int(recv(handle, buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), 0))
        #else
        recv(handle, buffer.baseAddress, buffer.count, 0)
        #endif
    }

    /// Sends everything, or gives up on the first error.
    static func sendAll(_ handle: Handle, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                #if os(Windows)
                let sent = Int(send(handle, raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                                    Int32(raw.count - offset), 0))
                #else
                let sent = send(handle, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                #endif
                if sent <= 0 { return }
                offset += sent
            }
        }
    }

    static func closeHandle(_ handle: Handle) {
        #if os(Windows)
        _ = closesocket(handle)
        #else
        _ = close(handle)
        #endif
    }
}
