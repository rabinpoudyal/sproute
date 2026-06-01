import Foundation

public enum PortError: Error, Equatable { case noFreePort }

public protocol PortProber: Sendable {
    func isFree(_ port: Int) -> Bool
}

/// Real prober: attempts to bind 127.0.0.1:<port>. If bind succeeds the port is free.
public struct BindPortProber: PortProber {
    public init() {}
    public func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

public struct PortAllocator: Sendable {
    let config: PortConfig
    let store: StateStore
    let prober: PortProber

    public init(config: PortConfig, store: StateStore, prober: PortProber) {
        self.config = config; self.store = store; self.prober = prober
    }

    public func allocate() throws -> Int {
        let held = Set(try store.load().map(\.port))
        for port in config.lower...config.upper {
            if held.contains(port) { continue }
            if prober.isFree(port) { return port }
        }
        throw PortError.noFreePort
    }
}
