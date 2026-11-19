import SwiftUI
import UIKit

struct DeviceDetailView: View {
    let device: DiscoveredDevice

    var body: some View {
        List {
            Section("基本信息") {
                LabeledContent("IP 地址", value: device.ip)
                LabeledContent("主机名", value: device.hostname ?? "未知")
                LabeledContent("发现方式", value: device.sources.map(\.rawValue).joined(separator: "、"))
                LabeledContent("可能角色", value: device.roleSummary)
            }

            if !device.openPorts.isEmpty {
                Section("开放端口") {
                    ForEach(device.openPorts, id: \.self) { port in
                        LabeledContent("\(port)", value: description(for: port))
                    }
                }
            }

            if !device.serviceNames.isEmpty {
                Section("Bonjour 服务类型") {
                    ForEach(device.serviceNames, id: \.self) { type in
                        Text(type).font(.caption.monospaced())
                    }
                }
            }

            Section("操作") {
                if let httpURL = URL(string: "http://\(device.ip)/") {
                    Link("打开 HTTP 管理页", destination: httpURL)
                }
                if let httpsURL = URL(string: "https://\(device.ip)/") {
                    Link("打开 HTTPS 管理页", destination: httpsURL)
                }
                Button("复制 IP 地址") {
                    UIPasteboard.general.string = device.ip
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
