import SwiftUI
import UIKit

struct DeviceDetailView: View {
    let device: DiscoveredDevice
    @EnvironmentObject var viewModel: ScannerViewModel
    @State private var isCheckingDHCP = false

    /// 从共享 ViewModel 里取最新设备数据，保证重新检测后能实时刷新。
    private var currentDevice: DiscoveredDevice {
        viewModel.devices.first { $0.ip == device.ip } ?? device
    }

    private var dhcpIcon: String {
        switch currentDevice.dhcpStatus {
        case .detected: return "checkmark.circle.fill"
        case .notDetected: return "xmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var dhcpColor: Color {
        switch currentDevice.dhcpStatus {
        case .detected: return .green
        case .notDetected: return .secondary
        case .failed: return .orange
        case .unknown: return .secondary
        }
    }

    private var dhcpTitle: String {
        switch currentDevice.dhcpStatus {
        case .detected: return "DHCP 服务器：已确认开启"
        case .notDetected: return "DHCP 服务器：未检测到"
        case .failed: return "DHCP 探测失败（可点下方重试）"
        case .unknown: return "DHCP 服务器：未检测"
        }
    }

    var body: some View {
        List {
            Section("DHCP 服务器检测") {
                HStack(spacing: 8) {
                    Image(systemName: dhcpIcon)
                        .foregroundStyle(dhcpColor)
                    Text(dhcpTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(dhcpColor)
                }

                if let info = currentDevice.dhcpInfo, info.success {
                    if let server = info.serverIP {
                        LabeledContent("服务器标识", value: server)
                    }
                    if let offered = info.offeredIP {
                        LabeledContent("可分配地址", value: offered)
                    }
                    if let mask = info.subnetMask {
                        LabeledContent("子网掩码", value: mask)
                    }
                    if let lease = info.leaseText {
                        LabeledContent("租约时长", value: lease)
                    }
                    if let router = info.routerIP {
                        LabeledContent("下发网关", value: router)
                    }
                    if !info.dnsServers.isEmpty {
                        LabeledContent("DNS", value: info.dnsServers.joined(separator: ", "))
                    }
                    if let port = info.sourcePort {
                        LabeledContent("本地接收端口", value: "\(port)")
                    }
                } else if let info = currentDevice.dhcpInfo {
                    Text(info.diagnostic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        isCheckingDHCP = true
                        await viewModel.recheckDHCP(for: device.ip)
                        isCheckingDHCP = false
                    }
                } label: {
                    if isCheckingDHCP {
                        HStack {
                            ProgressView()
                            Text("正在发送 DHCP 探测包…")
                        }
                    } else {
                        Label("重新检测 DHCP", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isCheckingDHCP)
            }

            Section("基本信息") {
                LabeledContent("IP 地址", value: currentDevice.ip)
                LabeledContent("主机名", value: currentDevice.hostname ?? "未知")
                LabeledContent("发现方式", value: currentDevice.sources.map(\.rawValue).joined(separator: "、"))
                LabeledContent("可能角色", value: currentDevice.roleSummary)
            }

            if !currentDevice.openPorts.isEmpty {
                Section("开放端口") {
                    ForEach(currentDevice.openPorts, id: \.self) { port in
                        LabeledContent("\(port)", value: description(for: port))
                    }
                }
            }

            if !currentDevice.serviceNames.isEmpty {
                Section("Bonjour 服务类型") {
                    ForEach(currentDevice.serviceNames, id: \.self) { type in
                        Text(type).font(.caption.monospaced())
                    }
                }
            }

            Section("操作") {
                if let httpURL = URL(string: "http://\(currentDevice.ip)/") {
                    Link("打开 HTTP 管理页", destination: httpURL)
                }
                if let httpsURL = URL(string: "https://\(currentDevice.ip)/") {
                    Link("打开 HTTPS 管理页", destination: httpsURL)
                }
                Button("复制 IP 地址") {
                    UIPasteboard.general.string = currentDevice.ip
                }
            }
        }
        .navigationTitle(device.hostname ?? device.ip)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func description(for port: Int) -> String {
        switch port {
        case 80: return "HTTP 管理界面"
        case 443: return "HTTPS"
        case 8080, 8081: return "备用 HTTP 管理端口"
        case 1900: return "UPnP（常见于路由器）"
        case 53: return "DNS 转发（常见于路由器）"
        case 22: return "SSH"
        case 23: return "Telnet"
        default: return "TCP 服务"
        }
    }
}
