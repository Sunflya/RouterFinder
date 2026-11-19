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
    static func isOpen(host: String, port: UInt16, timeout: TimeInterval = 0.55) async -> Bool {
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

    func scan(
        networkInfo: NetworkInfo,
        ports: [UInt16] = defaultPorts,
        progress: @escaping (Double, String) -> Void
    ) async -> [DiscoveredDevice] {
        let hosts = hostsToScan(for: networkInfo)
        let pairs = hosts.flatMap { ip in ports.map { (ip: ip, port: $0) } }
        let chunkSize = 32
        let chunks = pairs.chunked(into: chunkSize)

        var portsByHost: [String: [Int]] = [:]

        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { break }

            await withTaskGroup(of: (String, UInt16, Bool).self) { group in
                for pair in chunk {
                    group.addTask {
                        let open = await TCPProbe.isOpen(host: pair.ip, port: pair.port)
                        return (pair.ip, pair.port, open)
                    }
                }
                for await (ip, port, open) in group where open {
                    portsByHost[ip, default: []].append(Int(port))
                }
            }

            let done = min((index + 1) * chunkSize, pairs.count)
            progress(Double(done) / Double(max(1, pairs.count)), "已探测 \(done)/\(pairs.count) 个连接")
        }

        var devices = portsByHost.map { ip, ports in
            DiscoveredDevice(ip: ip, openPorts: ports, sources: [.portScan])
        }

        // 网关必定加入结果：即便管理端口未开放，它依然是 DHCP 服务器的最强候选
        let gateway = networkInfo.gatewayAddress
        if let idx = devices.firstIndex(where: { $0.ip == gateway }) {
            if !devices[idx].sources.contains(.gateway) {
                devices[idx].sources.append(.gateway)
            }
        } else {
            devices.append(DiscoveredDevice(ip: gateway, sources: [.gateway]))
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
