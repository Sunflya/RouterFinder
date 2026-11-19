import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ScannerViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("当前网络") {
                    if let info = viewModel.networkInfo {
                        LabeledContent("本机地址", value: info.cidrString)
                        LabeledContent("推测网关", value: info.gatewayAddress)
                        LabeledContent("扫描范围", value: "\(info.networkAddress) – \(info.broadcastAddress)（/24）")
                    } else {
                        Text("未连接到 Wi-Fi")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(action: { viewModel.toggleScan() }) {
                        HStack {
                            Image(systemName: viewModel.isScanning ? "stop.circle" : "radar")
                            Text(viewModel.isScanning ? "停止扫描" : "扫描局域网")
                        }
                    }

                    if viewModel.isScanning {
                        ProgressView(value: viewModel.progress)
                        Text(viewModel.progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("发现的设备（\(viewModel.devices.count)）") {
                    if viewModel.devices.isEmpty {
                        Text("点击上方按钮开始扫描。首次运行请在弹窗中允许「本地网络」权限。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.devices) { device in
                            NavigationLink(value: device) {
                                DeviceRow(device: device)
                            }
                        }
                    }
                }
            }
            .navigationTitle("路由器探测")
            .navigationDestination(for: DiscoveredDevice.self) { device in
                DeviceDetailView(device: device)
            }
            .onAppear { viewModel.refreshNetworkInfo() }
        }
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isLikelyRouter ? "router" : "network")
                .foregroundStyle(device.isLikelyRouter ? .orange : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.hostname ?? device.ip)
                        .font(.headline)
                    if device.isLikelyRouter {
                        Text("疑似路由器")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if device.dhcpStatus == .detected {
                        Text("DHCP ✓")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(device.ip + " · " + device.portSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
