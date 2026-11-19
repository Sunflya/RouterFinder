import Foundation

enum DiscoverySource: String, Hashable {
    case gateway = "网关推断"
    case portScan = "端口扫描"
    case bonjour = "Bonjour"
}

/// DHCP 服务器的判定状态
enum DHCPStatus: String, Hashable {
    case unknown = "未检测"
    case detected = "已确认开启"
    case notDetected = "未检测到"
    case failed = "探测失败"
}

struct DiscoveredDevice: Identifiable, Hashable {
    let id: String
    let ip: String
    var hostname: String?
    var openPorts: [Int]
    var sources: [DiscoverySource]
    var serviceNames: [String]
    var dhcpStatus: DHCPStatus = .unknown
    var dhcpInfo: DHCPProbeResult?

    init(
        ip: String,
        hostname: String? = nil,
        openPorts: [Int] = [],
        sources: [DiscoverySource] = [],
        serviceNames: [String] = [],
        dhcpStatus: DHCPStatus = .unknown,
        dhcpInfo: DHCPProbeResult? = nil
    ) {
        self.id = ip
        self.ip = ip
        self.hostname = hostname
        self.openPorts = openPorts.sorted()
        self.sources = sources
        self.serviceNames = serviceNames
        self.dhcpStatus = dhcpStatus
        self.dhcpInfo = dhcpInfo
    }

    /// 根据端口指纹和发现方式判断是否很可能是 DHCP 路由器
    var isLikelyRouter: Bool {
        if sources.contains(.gateway) { return true }
        let ports = Set(openPorts)
        if ports.contains(1900) && !Set([80, 443, 8080, 8081]).isDisjoint(with: ports) { return true }
        if ports.contains(53) && !Set([80, 443, 8080, 8081]).isDisjoint(with: ports) { return true }
        return false
    }

    var roleSummary: String {
        var roles: [String] = []
        if isLikelyRouter { roles.append("疑似 DHCP 路由器 / 网关") }
        if openPorts.contains(80) || openPorts.contains(8080) || openPorts.contains(8081) {
            roles.append("Web 管理界面")
        }
        if openPorts.contains(443) { roles.append("HTTPS 服务") }
        if openPorts.contains(1900) { roles.append("UPnP") }
        if openPorts.contains(53) { roles.append("DNS 转发") }
        if openPorts.contains(22) { roles.append("SSH") }
        if openPorts.contains(23) { roles.append("Telnet") }
        return roles.isEmpty ? "普通网络设备" : roles.joined(separator: "、")
    }

    var portSummary: String {
        openPorts.isEmpty ? "无已知端口开放" : "开放端口: " + openPorts.map(String.init).joined(separator: ", ")
    }
}

extension Array where Element == DiscoveredDevice {
    func ipNumber(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    var routerFirstSorted: [DiscoveredDevice] {
        sorted { lhs, rhs in
            if lhs.isLikelyRouter != rhs.isLikelyRouter { return lhs.isLikelyRouter }
            return ipNumber(lhs.ip) < ipNumber(rhs.ip)
        }
    }
}
