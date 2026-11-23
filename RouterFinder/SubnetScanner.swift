import Foundation
import Network

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// 用 TCP connect 判断端口是否开放（iOS 本地网络权限允许即可，无需越狱）
private enum TCPProbe {
    static func isOpen(host: String, port: UInt16, timeout: TimeInterval = 0.45) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            let connection = NWConnection(to: endpoint, using: .tcp)

            let lock = NSLock()
            var finished = false
            func finish(_ value: Bool) {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }
}

struct SubnetScanner {
    /// 小路由器最典型的管理/服务端口
    static let defaultPorts: [UInt16] = [80, 443, 8080, 8081, 1900, 53, 23, 22]
    /// 第一阶段只用三个"最容易命中"的端口快速筛活跃主机
    private static let quickPorts: [UInt16] = [80, 443, 1900]

    /// 两阶段扫描：先快速发现活跃主机，再只对它们做完整端口指纹。
    /// 相比对 254 个 IP × 8 端口全量探测，速度提升数倍。
    func scan(
        networkInfo: NetworkInfo,
        ports: [UInt16] = defaultPorts,
        priorityIPs: [String] = [],
        progress: @escaping (Double, String) -> Void
    ) async -> [DiscoveredDevice] {
        var candidates = Set(hostsToScan(for: networkInfo))
        candidates.insert(networkInfo.gatewayAddress)
        for ip in priorityIPs where !ip.isEmpty { candidates.insert(ip) }
        let hosts = candidates.sorted()

        // ---------- 阶段 1：快速存活探测 ----------
        var alive = Set<String>()
        let quickPairs = hosts.flatMap { ip in Self.quickPorts.map { (ip: ip, port: $0) } }
        let quickChunks = quickPairs.chunked(into: 72)
        for (index, chunk) in quickChunks.enumerated() {
            if Task.isCancelled { break }
            let found: [String] = await withTaskGroup(of: String?.self) { group in
                for pair in chunk {
                    group.addTask {
                        let open = await TCPProbe.isOpen(host: pair.ip, port: pair.port, timeout: 0.24)
                        return open ? pair.ip : nil
                    }
                }
                var ips: [String] = []
                for await ip in group { if let ip { ips.append(ip) } }
                return ips
            }
            alive.formUnion(found)
            let done = min((index + 1) * 72, quickPairs.count)
            progress(Double(done) / Double(max(1, quickPairs.count)) * 0.5,
                     "快速发现 \(done)/\(quickPairs.count)")
        }

        // 网关和 DHCP 服务器必定进入第二阶段，即使端口没命中
        alive.insert(networkInfo.gatewayAddress)
        for ip in priorityIPs where !ip.isEmpty { alive.insert(ip) }

        // ---------- 阶段 2：只对活跃主机做完整端口指纹 ----------
        let fullPairs = alive.sorted().flatMap { ip in ports.map { (ip: ip, port: $0) } }
        let fullChunks = fullPairs.chunked(into: 64)
        var portsByHost: [String: [Int]] = [:]
        for (index, chunk) in fullChunks.enumerated() {
            if Task.isCancelled { break }
            let opened: [(String, UInt16)] = await withTaskGroup(of: (String, UInt16)?.self) { group in
                for pair in chunk {
                    group.addTask {
                        let open = await TCPProbe.isOpen(host: pair.ip, port: pair.port, timeout: 0.45)
                        return open ? (pair.ip, pair.port) : nil
                    }
                }
                var result: [(String, UInt16)] = []
                for await item in group { if let item { result.append(item) } }
                return result
            }
            for (ip, port) in opened {
                portsByHost[ip, default: []].append(Int(port))
            }
            let done = min((index + 1) * 64, fullPairs.count)
            progress(0.5 + Double(done) / Double(max(1, fullPairs.count)) * 0.5,
                     "端口指纹 \(done)/\(fullPairs.count)")
        }

        var devices = portsByHost.map { ip, openPorts in
            DiscoveredDevice(ip: ip, openPorts: openPorts, sources: [.portScan])
        }

        let gateway = networkInfo.gatewayAddress
        if let idx = devices.firstIndex(where: { $0.ip == gateway }) {
            if !devices[idx].sources.contains(.gateway) {
                devices[idx].sources.append(.gateway)
            }
        } else {
            devices.append(DiscoveredDevice(ip: gateway, sources: [.gateway]))
        }
        for ip in priorityIPs where !ip.isEmpty && !devices.contains(where: { $0.ip == ip }) {
            devices.append(DiscoveredDevice(ip: ip, sources: [.gateway]))
        }

        return devices.routerFirstSorted
    }

    /// iOS 上限制在 /24 内扫描，避免 VPN/大型网段导致几万个探测任务
    private func hostsToScan(for info: NetworkInfo) -> [String] {
        let parts = info.ipAddress.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return [] }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        return (1...254)
            .map { "\(prefix).\($0)" }
            .filter { $0 != info.ipAddress && $0 != info.networkAddress && $0 != info.broadcastAddress }
    }
}
