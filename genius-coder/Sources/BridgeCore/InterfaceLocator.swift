import Foundation

/// Locates the addresses the bridge should bind: the current Wi-Fi/Ethernet
/// LAN IPv4 address and, when present, the Tailscale interface. The bridge
/// never listens on `0.0.0.0` (spec: 网络).
public struct InterfaceLocator {
    public struct BindAddress: Equatable {
        public enum Kind: String {
            case lan
            case tailscale
        }
        public var address: String
        public var kind: Kind
        public var interfaceName: String

        public init(address: String, kind: Kind, interfaceName: String) {
            self.address = address
            self.kind = kind
            self.interfaceName = interfaceName
        }
    }

    public init() {}

    /// Tailscale ranges: IPv4 100.64.0.0/10, IPv6 fd7a:115c:a1e0::/48.
    public static func isTailscaleIPv4(_ string: String) -> Bool {
        guard let addr = IPv4Address(string) else { return false }
        return addr.isIn100dot64slash10
    }

    public static func isTailscaleIPv6(_ string: String) -> Bool {
        guard let addr = IPv6Address(string) else { return false }
        return addr.isInTailscaleRange
    }

    public func currentBindAddresses() -> [BindAddress] {
        scanInterfaces() ?? []
    }

    private func scanInterfaces() -> [BindAddress]? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var out: [BindAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let ifa = current.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let family = sa.pointee.sa_family
            var converted = false
            if family == UInt8(AF_INET) {
                var addrCopy = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
                converted = withUnsafePointer(to: &addrCopy.sin_addr) {
                    inet_ntop(AF_INET, $0, &host, socklen_t(INET6_ADDRSTRLEN)) != nil
                }
            } else if family == UInt8(AF_INET6) {
                var addrCopy = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in6.self).pointee
                converted = withUnsafePointer(to: &addrCopy.sin6_addr) {
                    inet_ntop(AF_INET6, $0, &host, socklen_t(INET6_ADDRSTRLEN)) != nil
                }
            }
            guard converted else { continue }
            let address = String(cString: host)

            // Link-local, loopback and autoconf junk are skipped.
            if address.hasPrefix("fe80:") || address.hasPrefix("169.254.") { continue }

            if family == UInt8(AF_INET) {
                if Self.isTailscaleIPv4(address) {
                    out.append(BindAddress(address: address, kind: .tailscale, interfaceName: name))
                } else if name.hasPrefix("en") && !address.hasPrefix("127.") {
                    out.append(BindAddress(address: address, kind: .lan, interfaceName: name))
                }
            } else {
                if Self.isTailscaleIPv6(address) {
                    out.append(BindAddress(address: address, kind: .tailscale, interfaceName: name))
                }
            }
        }
        // Prefer one LAN + one Tailscale v4 (plus Tailscale v6 when present).
        var deduped: [BindAddress] = []
        for addr in out where !deduped.contains(where: { $0.address == addr.address }) {
            deduped.append(addr)
        }
        if deduped.count(where: { $0.kind == .lan }) > 1 {
            deduped.removeAll(where: { $0.kind == .lan && $0.interfaceName != "en0" })
        }
        return deduped
    }
}

/// Tiny IPv4/IPv6 parsers for range checks (no external deps).
struct IPv4Address {
    let octets: [UInt8]
    init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var o: [UInt8] = []
        for p in parts {
            guard let v = UInt8(p), !(p.count > 1 && p.hasPrefix("0")) else { return nil }
            o.append(v)
        }
        octets = o
    }

    var isIn100dot64slash10: Bool {
        octets[0] == 100 && (octets[1] & 0xC0) == 64
    }
}

struct IPv6Address {
    let bytes: [UInt8]
    init?(_ string: String) {
        var addr = in6_addr()
        let result = string.withCString { cs -> Int32 in
            inet_pton(AF_INET6, cs, &addr)
        }
        guard result == 1 else { return nil }
        bytes = withUnsafeBytes(of: addr) { Array($0) }
    }

    var isInTailscaleRange: Bool {
        // fd7a:115c:a1e0::/48
        bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c && bytes[4] == 0xa1 && bytes[5] == 0xe0
    }
}
