import Foundation
import Darwin

public enum NetError: Error, LocalizedError {
    case connectFailed(String)
    case timeout
    case closed
    case rejected(result: Int, source: Int, reason: Int)
    case aborted(source: Int, reason: Int)
    case protocolError(String)
    case noPresentationContext(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let s): return "Connection failed: \(s)"
        case .timeout: return "Connection timeout"
        case .closed: return "Connection terminated"
        case .rejected(let r, let s, let why):
            let reasons: [Int: String] = [1: "no reason given", 2: "application context not supported", 3: "calling AE title not recognized", 7: "called AE title not recognized"]
            return "Association rejected (\(r == 1 ? "permanent" : "transient"), source \(s): \(s == 1 ? (reasons[why] ?? "reason \(why)") : "reason \(why)"))"
        case .aborted(let s, let r): return "Association aborted (source \(s), reason \(r))"
        case .protocolError(let s): return "Protocol error: \(s)"
        case .noPresentationContext(let s): return "No accepted presentation context for \(s)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Minimal blocking TCP socket with timeouts. Used from background threads only.
public final class TCPSocket: @unchecked Sendable {
    let fd: Int32
    public private(set) var peerAddress: String = ""
    public var timeout: TimeInterval { didSet { applyTimeout() } }
    private let lock = NSLock()
    private var isClosed = false

    init(fd: Int32, timeout: TimeInterval) {
        self.fd = fd
        self.timeout = timeout
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        applyTimeout()
        peerAddress = Self.peerName(fd)
    }

    deinit { close() }

    private func applyTimeout() {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func connect(host: String, port: Int, timeout: TimeInterval) throws -> TCPSocket {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw NetError.connectFailed(String(cString: gai_strerror(rc))) }
        defer { freeaddrinfo(first) }
        var lastError = "no address"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { continue }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var r = Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen)
            if r != 0 && errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let n = poll(&p, 1, Int32(timeout * 1000))
                if n == 1 {
                    var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    r = err == 0 ? 0 : -1
                    if err != 0 { lastError = String(cString: strerror(err)) }
                } else {
                    lastError = n == 0 ? "timeout" : String(cString: strerror(errno))
                    r = -1
                }
            } else if r != 0 {
                lastError = String(cString: strerror(errno))
            }
            if r == 0 {
                _ = fcntl(fd, F_SETFL, flags)
                return TCPSocket(fd: fd, timeout: timeout)
            }
            Darwin.close(fd)
        }
        if lastError == "timeout" { throw NetError.timeout }
        throw NetError.connectFailed(lastError)
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.send(fd, p, left, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw NetError.timeout }
                    throw NetError.closed
                }
                left -= n
                p += n
            }
        }
    }

    public func read(exactly count: Int) throws -> Data {
        var out = Data(count: count)
        var got = 0
        try out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while got < count {
                let n = Darwin.recv(fd, base + got, count - got, 0)
                if n == 0 { throw NetError.closed }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw NetError.timeout }
                    throw NetError.closed
                }
                got += n
            }
        }
        return out
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if isClosed { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    static func peerName(_ fd: Int32) -> String {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) } }
        guard ok == 0 else { return "" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        _ = withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) } }
        var s = String(cString: host)
        if s.hasPrefix("::ffff:") { s.removeFirst(7) }
        return s
    }
}

/// Listening TCP socket (IPv6 dual-stack).
public final class TCPListener: @unchecked Sendable {
    let fd: Int32
    public let port: Int
    private var stopped = false

    /// `loopbackOnly` binds to ::1/127.0.0.1 instead of all interfaces.
    public init(port: Int, loopbackOnly: Bool = false) throws {
        let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw NetError.connectFailed(String(cString: strerror(errno))) }
        var on: Int32 = 1, off: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port).bigEndian)
        addr.sin6_addr = in6addr_any
        if loopbackOnly {
            // ::ffff:127.0.0.1 keeps IPv4 clients working on the dual-stack socket
            var mapped = in6_addr()
            inet_pton(AF_INET6, "::ffff:127.0.0.1", &mapped)
            addr.sin6_addr = mapped
        }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        guard r == 0, listen(fd, 16) == 0 else {
            let e = String(cString: strerror(errno)); Darwin.close(fd)
            throw NetError.connectFailed(e)
        }
        self.fd = fd
        self.port = port
    }

    /// Blocks until a client connects; returns nil once stopped.
    public func accept(timeout: TimeInterval) -> TCPSocket? {
        while !stopped {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, 500)
            if stopped { return nil }
            if n <= 0 { continue }
            let c = Darwin.accept(fd, nil, nil)
            if c >= 0 { return TCPSocket(fd: c, timeout: timeout) }
        }
        return nil
    }

    public func stop() {
        if stopped { return }
        stopped = true
        Darwin.close(fd)
    }

    deinit { stop() }
}

/// Classifies a peer address for the listener's "Accept connections" filter.
public enum PeerAddress {
    public static func isLocalNetwork(_ ip: String) -> Bool {
        if ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("169.254.") || ip.lowercased().hasPrefix("fe80:") || ip.lowercased().hasPrefix("fd") || ip.lowercased().hasPrefix("fc") { return true }
        if ip.hasPrefix("172."), let second = Int(ip.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) { return true }
        return false
    }
}
