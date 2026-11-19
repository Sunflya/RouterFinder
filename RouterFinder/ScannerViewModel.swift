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

            let subnet = SubnetScanner()
            let portDevices = await subnet.scan(networkInfo: info) { value, text in
                Task { @MainActor [weak self] in
                    guard let self = self, self.scanGeneration == generation else { return }
                    self.progress = value * 0.85
                    self.progressText = text
                }
            }

            guard !Task.isCancelled, self.scanGeneration == generation else { return }

            let bonjourDevices = await self.runBonjour()

            guard !Task.isCancelled, self.scanGeneration == generation else { return }

            var merged: [String: DiscoveredDevice] = [:]
            for device in portDevices + bonjourDevices {
                Self.merge(device, into: &merged)
            }

            self.devices = Array(merged.values).routerFirstSorted
            self.progress = 1
            self.progressText = "扫描完成，发现 \(self.devices.count) 台设备"
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

    private func runBonjour() async -> [DiscoveredDevice] {
        progressText = "正在通过 Bonjour 发现服务…"
        let results = BonjourResults()
        return await withCheckedContinuation { continuation in
            let scanner = BonjourScanner()
            scanner.start(
                timeout: 3.5,
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
