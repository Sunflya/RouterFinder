import SwiftUI

struct WifiView: View {
    @State private var networks: [WifiNetworkInfo] = []
    @State private var isScanning = false
    @State private var diagnostic = "尚未扫描（需要越狱环境与 WiFi 私有权限）"

    var body: some View {
        List {
            Section {
                Button {
                    scan()
                } label: {
                    HStack {
                        Image(systemName: isScanning ? "hourglass" : "wifi.radar")
                        Text(isScanning ? "正在扫描附近 WiFi…" : "扫描附近 WiFi")
                    }
                }
                .disabled(isScanning)

                Text(diagnostic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("附近网络（\(networks.count)）") {
                if networks.isEmpty {
                    Text("点击上方按钮开始扫描。iOS 14+ 通过 MobileWiFi 私有接口读取信号强度与频宽，需要越狱环境及对应权限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(networks.enumerated()), id: \.offset) { _, net in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "wifi")
                                .foregroundStyle(net.signalColor)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(net.ssid)
                                        .font(.headline)
                                    Spacer()
                                    Text(net.rssiText)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(net.signalColor)
                                }
                                Text("\(net.band) · 信道 \(net.channel > 0 ? String(net.channel) : "?") · 频宽 \(net.channelWidth)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("信号 \(net.signalPercentText) · \(net.security) · \(net.bssid)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("WiFi 频谱")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scan() {
        isScanning = true
        diagnostic = "正在通过 MobileWiFi 私有接口扫描…"
        DispatchQueue.global(qos: .userInitiated).async {
            let found = WifiProber.scanNearby()
            let message = WifiProber.diagnostic()
            DispatchQueue.main.async {
                networks = found.sorted { a, b in
                    let av = a.hasValidRSSI
                    let bv = b.hasValidRSSI
                    if av && bv { return a.rssi > b.rssi }
                    if av { return true }
                    if bv { return false }
                    return a.ssid < b.ssid
                }
                diagnostic = message
                isScanning = false
            }
        }
    }
}

private extension WifiNetworkInfo {
    /// 0 dBm 是无效读数（iOS 私有接口取不到时的默认值），绝不能当成满格
    var hasValidRSSI: Bool {
        rssi >= -127 && rssi <= -10
    }

    var rssiText: String {
        hasValidRSSI ? "\(rssi) dBm" : "未知 dBm"
    }

    var signalPercent: Int? {
        guard hasValidRSSI else { return nil }
        if rssi >= -40 { return 100 }
        if rssi <= -95 { return 0 }
        return max(0, min(100, (rssi + 95) * 100 / 55))
    }

    var signalPercentText: String {
        guard let p = signalPercent else { return "未知" }
        return "\(p)%"
    }

    var signalColor: Color {
        guard hasValidRSSI else { return .gray }
        if rssi >= -55 { return .green }
        if rssi >= -70 { return .orange }
        return .red
    }
}
