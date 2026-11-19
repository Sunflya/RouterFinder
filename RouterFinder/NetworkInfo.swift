import Foundation
import SystemConfiguration

struct NetworkInfo {
    let interfaceName: String
    let ipAddress: String
    let subnetMask: String
    let gatewayAddress: String
    let networkAddress: String
    let broadcastAddress: String
    let prefixLength: Int

    var cidrString: String { "\(ipAddress)/\(prefixLength)" }

    static func detect() -> NetworkInfo? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ifa.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }

            let ip = string(from: addr)
            guard !ip.isEmpty, ip != "0.0.0.0" else { continue }

            let mask = ifa.ifa_netmask.map { string(from: $0) } ?? "255.255.255.0"
            let ipParts = octets(of: ip)
            let maskParts = octets(of: mask)
            guard ipParts.count == 4, maskParts.count == 4 else { continue }

            let netParts = zip(ipParts, maskParts).map { $0 & $1 }
            let broadcastParts = zip(netParts, maskParts).map { $0 | (255 - $1) }
            let prefix = maskParts.map { octet -> Int in
                var v = octet, count = 0
                while v & 0x80 != 0 { count += 1; v <<= 1 }
                return count
            }.reduce(0, +)

            // 家庭/小型网络里网关通常是网段第一个可用地址；.254 作为备选由端口扫描兜底
            let gateway = incremented(ip: join(netParts), by: 1) ?? join(netParts)

            return NetworkInfo(
                interfaceName: name,
                ipAddress: ip,
                subnetMask: mask,
                gatewayAddress: gateway,
                networkAddress: join(netParts),
                broadcastAddress: join(broadcastParts),
                prefixLength: prefix
            )
        }
        return nil
    }

    // MARK: - Helpers

    private static func string(from sa: UnsafeMutablePointer<sockaddr>) -> String {
        var address = sa.pointee
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            &address,
            socklen_t(address.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        return status == 0 ? String(cString: host) : ""
    }

    private static func octets(of ip: String) -> [Int] {
        ip.split(separator: ".").compactMap { Int($0) }
    }

    private static func join(_ parts: [Int]) -> String {
        parts.map(String.init).joined(separator: ".")
    }

    private static func incremented(ip: String, by delta: Int) -> String? {
        let parts = octets(of: ip)
        guard parts.count == 4 else { return nil }
        let value = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        let next = value + delta
        let result = [
            (next >> 24) & 0xFF,
            (next >> 16) & 0xFF,
            (next >> 8) & 0xFF,
            next & 0xFF
        ]
        return join(result)
    }
}
