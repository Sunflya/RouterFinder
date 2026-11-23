import Foundation

@MainActor
final class ScannerViewModel: ObservableObject {
    @Published var networkInfo: NetworkInfo?
    @Published var devices: [DiscoveredDevice] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var progressText = ""
    @Published var errorMessage: String?

    private var bonjourScanner: BonjourScanner?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    private final class BonjourResults {
        var items: [DiscoveredDevice] = []
    }

    func refreshNetworkInfo() {
        networkInfo = NetworkInfo.detect()
        if networkInfo == nil {
            errorMessage = "未检测到 Wi-Fi 连接，请连接局域网后重试。"
        }
    }

    func toggleScan() {
        isScanning ? stopScan() : startScan()
    }

    func startScan() {
        guard !isScanning else { return }
        guard let info = NetworkInfo.detect() else {
            errorMessage = "未检测到 Wi-Fi 连接，请连接局域网后重试。"
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        networkInfo = info
        isScanning = true
        progress = 0
        devices = []
        errorMessage = nil

        scanTask = Task { [weak self] in
            guard let self = self else { return }

            // DHCP 广播探测与端口扫描并行执行，避免串行等待叠加耗时
            async let dhcpResult = DHCPProber.probeNetwork()
            let subnet = SubnetScanner()
            let portDevices = await subnet.scan(networkInfo: info, priorityIPs: [info.gatewayAddress]) { value, text in
                Task { @MainActor [weak self] in
                    guard let self = self, self.scanGeneration == generation else { return }
                    self.progress = value * 0.9
                    self.progressText = text
                }
            }

            guard !Task.isCancelled, self.scanGeneration == generation else { return }

            let bonjourDevices = await self.runBonjour(timeout: 2.0)

            guard !Task.isCancelled, self.scanGeneration == generation else { return }

            var merged: [String: DiscoveredDevice] = [:]
            for device in portDevices + bonjourDevices {
                Self.merge(device, into: &merged)
            }

            let dhcp = await dhcpResult
            guard !Task.isCancelled, self.scanGeneration == generation else { return }
            Self.applyDHCP(dhcp, to: &merged)

            self.devices = Array(merged.values).routerFirstSorted
            self.progress = 1
            let dhcpCount = self.devices.filter { $0.dhcpStatus == .detected }.count
            self.progressText = "扫描完成，发现 \(self.devices.count) 台设备" + (dhcpCount > 0 ? "，其中 \(dhcpCount) 台开启 DHCP" : "")
            self.isScanning = false
            self.bonjourScanner = nil
        }
    }

    func stopScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        bonjourScanner?.cancel()
        bonjourScanner = nil
        isScanning = false
        progressText = "已停止扫描"
    }

    private func runBonjour(timeout: TimeInterval = 2.0) async -> [DiscoveredDevice] {
        progressText = "正在通过 Bonjour 发现服务…"
        let results = BonjourResults()
        return await withCheckedContinuation { continuation in
            let scanner = BonjourScanner()
            scanner.start(
                timeout: timeout,
                onFound: { device in
                    DispatchQueue.main.async { results.items.append(device) }
                },
                completion: {
                    continuation.resume(returning: results.items)
                }
            )
            self.bonjourScanner = scanner
        }
    }

    /// 把 DHCP 广播探测结果应用到设备：Offer 的 Server Identifier 就是 DHCP 服务器真实 IP。
    private static func applyDHCP(_ result: DHCPProbeResult, to devices: inout [String: DiscoveredDevice]) {
        guard result.success, let serverIP = result.serverIP else {
            // 探测失败时，给最像路由器的设备标注失败，便于用户手动复测
            if let gateway = devices.values.first(where: { $0.sources.contains(.gateway) }) {
                var updated = gateway
                updated.dhcpStatus = .failed
                updated.dhcpInfo = result
                devices[gateway.ip] = updated
            }
            return
        }

        if var server = devices[serverIP] {
            server.dhcpStatus = .detected
            server.dhcpInfo = result
            if !server.sources.contains(.gateway) { server.sources.append(.gateway) }
            devices[serverIP] = server
        } else {
            // DHCP 服务器没被端口扫描发现（很常见，DHCP 不一定开那些端口），补一台进去
            let device = DiscoveredDevice(
                ip: serverIP,
                openPorts: [],
                sources: [.gateway],
                dhcpStatus: .detected,
                dhcpInfo: result
            )
            devices[serverIP] = device
        }
    }

    /// 详情页手动对单台设备做定向 DHCP 检测。
    func recheckDHCP(for ip: String) async {
        let result = await DHCPProber.probe(host: ip)
        guard let index = devices.firstIndex(where: { $0.ip == ip }) else { return }
        devices[index].dhcpInfo = result
        devices[index].dhcpStatus = result.success ? .detected : .notDetected
    }

    private static func merge(_ device: DiscoveredDevice, into dict: inout [String: DiscoveredDevice]) {
        if var existing = dict[device.ip] {
            existing.openPorts = Array(Set(existing.openPorts + device.openPorts)).sorted()
            existing.sources = Array(Set(existing.sources + device.sources))
            existing.serviceNames = Array(Set(existing.serviceNames + device.serviceNames))
            if existing.hostname == nil { existing.hostname = device.hostname }
            dict[device.ip] = existing
        } else {
            dict[device.ip] = device
        }
    }
}
