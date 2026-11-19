import Foundation

/// 通过 Bonjour / mDNS 发现局域网里 announcing 服务的设备（打印机、NAS、AirPlay、路由管理页等）
final class BonjourScanner: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let serviceTypes = [
        "_http._tcp.",
        "_https._tcp.",
        "_raop._tcp.",
        "_airplay._tcp.",
        "_ipp._tcp.",
        "_printer._tcp.",
        "_smb._tcp.",
        "_ssh._tcp.",
        "_services._dns-sd._udp."
    ]

    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var foundHandler: ((DiscoveredDevice) -> Void)?
    private var completionHandler: (() -> Void)?
    private var isFinished = false

    func start(
        timeout: TimeInterval = 3.5,
        onFound: @escaping (DiscoveredDevice) -> Void,
        completion: @escaping () -> Void
    ) {
        foundHandler = onFound
        completionHandler = completion
        isFinished = false

        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        for type in serviceTypes {
            browser.searchForServices(ofType: type, inDomain: "local.")
        }

        // 关键：这里必须强引用 self。若使用 [weak self]，外部在超时前释放 scanner
        // 时回调不会触发，ScannerViewModel 里的 continuation 将永远挂起。
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in
            self.finish()
        }
    }

    /// 允许外部（例如用户停止扫描）提前结束，保证 continuation 一定被恢复。
    func cancel() {
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true

        browser?.delegate = nil
        browser?.stop()
        browser = nil
        for service in services { service.delegate = nil }
        services.removeAll()

        let handler = completionHandler
        completionHandler = nil
        foundHandler = nil
        handler?()
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 === service }
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let address = sender.addresses?.first, let ip = ipv4String(from: address) else { return }
        let device = DiscoveredDevice(
            ip: ip,
            hostname: sender.hostName,
            sources: [.bonjour],
            serviceNames: [sender.type]
        )
        foundHandler?(device)
    }

    // MARK: - Helpers

    private func ipv4String(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer -> String? in
            guard let base = rawBuffer.baseAddress else { return nil }
            var address = base.assumingMemoryBound(to: sockaddr.self).pointee
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
            guard status == 0 else { return nil }
            let ip = String(cString: host)
            return ip.contains(":") ? nil : ip // 只保留 IPv4
        }
    }
}
