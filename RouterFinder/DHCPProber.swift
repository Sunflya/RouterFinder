import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - 数据模型

/// DHCP 探测结论。可 Hashable，便于放进 DiscoveredDevice。
struct DHCPProbeResult: Hashable {
    let success: Bool
    let serverIP: String?          // option 54 Server Identifier
    let offeredIP: String?         // yiaddr，服务器打算分配的地址
    let leaseSeconds: UInt32?      // option 51
    let subnetMask: String?        // option 1
    let routerIP: String?          // option 3
    let dnsServers: [String]       // option 6
    let broadcastIP: String?       // option 28
    let sourcePort: UInt16?        // 本地用于接收的端口
    let diagnostic: String         // 给排错用的说明

    var summary: String {
        if !success { return "未检测到 DHCP 回应" }
        return "DHCP 服务器 \(serverIP ?? "未知")"
    }

    var leaseText: String? {
        guard let s = leaseSeconds else { return nil }
        if s >= 86400 && s % 86400 == 0 { return "\(s / 86400) 天" }
        if s >= 3600 && s % 3600 == 0 { return "\(s / 3600) 小时" }
        if s >= 60 { return "\(s / 60) 分钟" }
        return "\(s) 秒"
    }
}

// MARK: - 探测器

/// 通过主动发送 DHCP Discover / 监听 DHCP Offer 来判断某台设备是否真的在运行 DHCP 服务器。
/// 这是唯一可靠的方法——端口扫描只能猜，DHCP 握手才是确凿证据。
enum DHCPProber {

    /// 网络级探测：广播 Discover，找出当前网络里真正响应的 DHCP 服务器。
    static func probeNetwork(timeout: TimeInterval = 3.0) async -> DHCPProbeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: probeSync(targetIP: nil, timeout: timeout))
            }
        }
    }

    /// 定向探测：向指定 IP 单播 Discover，判断「这一台」是否开了 DHCP 服务。
    static func probe(host: String, timeout: TimeInterval = 3.0) async -> DHCPProbeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: probeSync(targetIP: host, timeout: timeout))
            }
        }
    }

    // MARK: 内部实现

    /// 多策略尝试：68（能绑到就最可靠）→ 高位端口（依赖服务器回显源端口）。
    private static func probeSync(targetIP: String?, timeout: TimeInterval) -> DHCPProbeResult {
        let ports: [UInt16] = [68, 1068, 6767, 15432]
        var notes: [String] = []

        for port in ports {
            let outcome = attempt(port: port, targetIP: targetIP, timeout: timeout)
            if outcome.success { return outcome }
            notes.append(outcome.diagnostic)
        }
        return DHCPProbeResult(
            success: false,
            serverIP: nil, offeredIP: nil, leaseSeconds: nil,
            subnetMask: nil, routerIP: nil, dnsServers: [], broadcastIP: nil,
            sourcePort: nil,
            diagnostic: notes.joined(separator: "；")
        )
    }

    private static func attempt(port: UInt16, targetIP: String?, timeout: TimeInterval) -> DHCPProbeResult {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return fail("创建 UDP socket 失败 errno=\(errno)")
        }
        defer { close(fd) }

        var yes: Int32 = 1
        let optLen = socklen_t(MemoryLayout<Int32>.size)
        withUnsafePointer(to: &yes) { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, optLen) }
        withUnsafePointer(to: &yes) { setsockopt(fd, SOL_SOCKET, SO_BROADCAST, $0, optLen) }
        #if canImport(Darwin)
        withUnsafePointer(to: &yes) { setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, $0, optLen) }
        #endif

        // 绑定本地端口
        guard var local = makeSockaddr(ip: "0.0.0.0", port: port) else {
            return fail("构造本地地址失败")
        }
        let bindOK = withUnsafePointer(to: &local) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !bindOK {
            return fail("绑定端口 \(port) 失败 errno=\(errno)")
        }

        let xid = UInt32.random(in: 1...UInt32.max)
        var mac = (0..<6).map { _ in UInt8.random(in: 0...255) }
        mac[0] = (mac[0] | 0x02) & 0xFE   // 本地管理地址，清掉组播位
        let packet = buildDiscover(xid: xid, chaddr: mac)

        // 目标：定向探测用指定 IP，网络探测用广播
        let destination = targetIP ?? "255.255.255.255"
        guard var dest = makeSockaddr(ip: destination, port: 67) else {
            return fail("构造目标地址失败")
        }
        let sent = packet.withUnsafeBytes { bp -> Int in
            withUnsafePointer(to: &dest) { dp in
                dp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    sendto(fd, bp.baseAddress, bp.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else {
            return fail("发送 Discover 失败 errno=\(errno)")
        }

        // 等待 Offer
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var fds = fd_set()
            FD_ZERO(&fds)
            FD_SET(fd, &fds)
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            let ready = withUnsafeMutablePointer(to: &fds) { fp -> Int32 in
                withUnsafeMutablePointer(to: &tv) { tp in
                    select(fd + 1, fp, nil, nil, tp)
                }
            }
            if ready <= 0 { continue }
            let isSet = withUnsafeMutablePointer(to: &fds) { fp -> Bool in FD_ISSET(fd, fp) != 0 }
            guard isSet else { continue }

            var buffer = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { bp -> Int in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        recvfrom(fd, bp.baseAddress, bp.count, 0, sp, &fromLen)
                    }
                }
            }
            guard n > 0 else { continue }

            // 定向探测时，确认回包确实来自目标
            if let target = targetIP {
                let fromIP = sockaddrToString(from)
                if fromIP != target && fromIP != "255.255.255.255" { continue }
            }

            if var result = parseOffer(Array(buffer[0..<n]), xid: xid) {
                result.sourcePort = port
                return result
            }
        }
        return fail(port == 68 ? "端口 68 已响应但超时未收到合法 Offer" : "端口 \(port) 超时未收到 Offer")
    }

    // MARK: DHCP 报文

    /// 构造 DHCPDISCOVER（BOOTP 头 + Magic Cookie + Options）
    private static func buildDiscover(xid: UInt32, chaddr: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 240)
        p[0] = 1                    // op = BOOTREQUEST
        p[1] = 1                    // htype = Ethernet
        p[2] = 6                    // hlen
        p[3] = 0                    // hops
        p[4] = UInt8((xid >> 24) & 0xFF)
        p[5] = UInt8((xid >> 16) & 0xFF)
        p[6] = UInt8((xid >> 8) & 0xFF)
        p[7] = UInt8(xid & 0xFF)
        p[10] = 0x80                // flags: 广播回应
        for i in 0..<6 { p[28 + i] = chaddr[i] }
        // Magic Cookie 99.130.83.99
        p[236] = 0x63; p[237] = 0x82; p[238] = 0x53; p[239] = 0x63

        p.append(53); p.append(1); p.append(1)                       // DHCPDISCOVER
        p.append(55); p.append(6); p.append(contentsOf: [1, 3, 6, 28, 51, 54])
        p.append(61); p.append(7); p.append(1); p.append(contentsOf: chaddr)
        p.append(255)                                                // End
        return p
    }

    /// 解析 DHCPOFFER，提取服务器标识与租约参数
    private static func parseOffer(_ data: [UInt8], xid: UInt32) -> DHCPProbeResult? {
        guard data.count >= 240 else { return nil }
        guard data[0] == 2 else { return nil }   // BOOTREPLY
        let rxid = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16) | (UInt32(data[6]) << 8) | UInt32(data[7])
        guard rxid == xid else { return nil }
        guard data[236] == 0x63, data[237] == 0x82, data[238] == 0x53, data[239] == 0x63 else { return nil }

        var msgType: UInt8 = 0
        var serverIP: String?
        var offeredIP = ipFrom(data[16..<20])
        var lease: UInt32?
        var mask: String?
        var router: String?
        var dns: [String] = []
        var broadcast: String?

        var i = 240
        while i < data.count {
            let code = data[i]; i += 1
            if code == 255 { break }
            if code == 0 { continue }
            guard i < data.count else { break }
            let len = Int(data[i]); i += 1
            guard i + len <= data.count else { break }
            let value = Array(data[i..<(i + len)]); i += len

            switch code {
            case 53: if let first = value.first { msgType = first }
            case 54: if value.count >= 4 { serverIP = ipFrom(value[0..<4]) }
            case 51: if value.count >= 4 {
                lease = (UInt32(value[0]) << 24) | (UInt32(value[1]) << 16) | (UInt32(value[2]) << 8) | UInt32(value[3])
            }
            case 1:  if value.count >= 4 { mask = ipFrom(value[0..<4]) }
            case 3:  if value.count >= 4 { router = ipFrom(value[0..<4]) }
            case 6:
                var j = 0
                while j + 4 <= value.count { dns.append(ipFrom(value[j..<(j + 4)])); j += 4 }
            case 28: if value.count >= 4 { broadcast = ipFrom(value[0..<4]) }
            default: break
            }
        }

        guard msgType == 2 else { return nil }   // DHCPOFFER

        return DHCPProbeResult(
            success: true,
            serverIP: serverIP,
            offeredIP: offeredIP,
            leaseSeconds: lease,
            subnetMask: mask,
            routerIP: router,
            dnsServers: dns,
            broadcastIP: broadcast,
            sourcePort: nil,
            diagnostic: "收到 DHCPOFFER"
        )
    }

    // MARK: 工具

    private static func fail(_ message: String) -> DHCPProbeResult {
        DHCPProbeResult(
            success: false, serverIP: nil, offeredIP: nil, leaseSeconds: nil,
            subnetMask: nil, routerIP: nil, dnsServers: [], broadcastIP: nil,
            sourcePort: nil, diagnostic: message
        )
    }

    private static func makeSockaddr(ip: String, port: UInt16) -> sockaddr_in? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let value = (UInt32(parts[0]) << 24) | (UInt32(parts[1]) << 16) | (UInt32(parts[2]) << 8) | UInt32(parts[3])
        addr.sin_addr.s_addr = value.bigEndian
        return addr
    }

    private static func sockaddrToString(_ addr: sockaddr_in) -> String {
        let a = addr.sin_addr.s_addr
        let b0 = UInt8((a >> 0) & 0xFF)
        let b1 = UInt8((a >> 8) & 0xFF)
        let b2 = UInt8((a >> 16) & 0xFF)
        let b3 = UInt8((a >> 24) & 0xFF)
        return "\(b0).\(b1).\(b2).\(b3)"
    }

    private static func ipFrom<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map(String.init).joined(separator: ".")
    }
}
