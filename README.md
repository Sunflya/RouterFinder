# 路由器探测（RouterFinder）

一个 iOS 应用，用于发现局域网中的 DHCP 小路由器和其他网络设备，支持 **iOS 17.2 / 17.2.1 及以上**。

## 重要说明：关于“生成 IPA”

Windows 上无法直接编译 iOS App：打包 IPA 需要 macOS + Xcode + iOS SDK。但你的 iPhone 已越狱，**签名不是问题**——用 `ldid` 假签名即可，不需要苹果证书。本仓库的 GitHub Actions 会在云端 macOS 上完成编译、假签名和打包，你只需要下载产物。

iOS 沙箱不允许抓 DHCP 广播（需要私有端口 67/68 或 VPN 权限），所以本应用采用合规替代方案：

1. **网关推断**：读取 Wi‑Fi 的 IP/掩码，推断网段网关；
2. **TCP 端口指纹**：扫描 /24 内的 80/443/8080/1900/53 等端口，识别路由器管理页与 UPnP/DNS 服务；
3. **Bonjour / mDNS**：发现局域网内宣告服务的设备。

三者结果合并，疑似路由器排在列表最前面。

## 目录结构

```
RouterFinder/                              ← 仓库根目录
├── project.yml                            # XcodeGen 工程定义（部署目标 iOS 17.2）
├── build.sh                               # 打包脚本（越狱/自动/手动三种模式）
├── entitlements.plist                     # ldid 假签名权限声明
├── ExportOptions*.template.plist          # 签名导出配置模板
├── .github/workflows/build-ipa.yml        # 云端构建：ldid 假签名 IPA
└── RouterFinder/                          # SwiftUI 源码（必须随仓库一起上传）
    ├── RouterFinderApp.swift
    ├── ContentView.swift
    ├── DeviceDetailView.swift
    ├── Models.swift
    ├── NetworkInfo.swift
    ├── SubnetScanner.swift
    ├── BonjourScanner.swift
    └── ScannerViewModel.swift
```

> ⚠️ 之前 GitHub 上报错
> `Spec validation error: Target "RouterFinder" has a missing source directory`
> 的原因就是仓库里**缺少 `RouterFinder/` 这个 Swift 源码目录**，或者旧 workflow 把文件错误地移动到了 `RouterFinder/RouterFinder/`。
> 现在已修复：新 workflow **不会移动任何文件**，但你必须把本地这个 `RouterFinder/` 源码目录一起提交到 GitHub。

## 🍎 越狱用户推荐方案（无需证书、无需 Mac）

### 方式 1：GitHub Actions 云端构建（推荐）

1. 把本工程**整个目录**（包括里面的 `RouterFinder/` 子目录）推到你自己的 GitHub 仓库：
   ```bash
   cd RouterFinder
   git init
   git add .
   git commit -m "fix: build jailbreak ipa"
   git remote add origin https://github.com/你的用户名/你的仓库.git
   git push -u origin main -f
   ```
   如果你已经有仓库，直接 `git add . && git commit && git push` 即可。
2. 打开仓库网页 → **Actions** 标签页 → 找到 **Build jailbreak IPA** → 点 **Run workflow**；
3. 等 5～10 分钟，构建完成后在本次运行页面底部 **Artifacts** 下载 `RouterFinder-jailbroken-ipa`；
4. 解压得到 `RouterFinder-jailbroken.ipa` 和 `.sha256.txt`，用 AirDrop 或数据线传到手机；
5. 在手机的 **Filza** 里找到 IPA → 点击 → 选「安装」（需先装好 **AppSync Unified** 绕过签名校验）。

> 新 workflow 固定在 `macos-15` + `Xcode 16.4`，并会在打包后校验 IPA 内的 Bundle ID，避免旧版 `macos-14` 已退役导致构建失败。

### 方式 2：自己在 Mac 上编译

```bash
cd RouterFinder
brew install xcodegen ldid
JAILBREAK=1 ./build.sh
```

产物在 `build/ipa/RouterFinder-jailbroken.ipa`，同样用 Filza 安装。

---

## 未越狱用户的方案（需要签名）

### 方案 A：Xcode 直接装到手机

1. Mac 上安装 Xcode 15.1+ 和 XcodeGen：`brew install xcodegen`；
2. `xcodegen generate && open RouterFinder.xcodeproj`；
3. Xcode 中选中 target `RouterFinder` → **Signing & Capabilities** → Team 选你的个人团队；
4. 把 **Bundle Identifier** 改成全局唯一值，例如 `com.yourname.routerfinder`；
5. 数据线连接 iPhone，点「信任此电脑」，选设备后按 **⌘R**；
6. 首次打开 App 弹窗「想查找并连接到本地网络上的设备」→ 必须点**允许**。

> iOS 17.2.1 是 17.2 的补丁版本，Deployment Target 设为 17.2 即可覆盖。

### 方案 B：命令行生成签名 IPA

```bash
TEAM_ID=你的团队ID BUNDLE_ID=com.yourname.routerfinder METHOD=ad-hoc ./build.sh
```

产物在 `build/ipa/RouterFinder.ipa`。

### 方案 C：AltStore / Sideloadly 侧载

把 IPA 拖入工具，输入 Apple ID（建议用应用专用密码），它会自动重签并安装。免费签名 7 天过期，需定期刷新。

## 使用方式

1. 连接 Wi‑Fi，打开 App，点「扫描局域网」；
2. 等待约 20～40 秒，列表按“疑似路由器优先”排序；
3. 点设备可查看开放端口、服务类型，并可一键打开 `http://设备IP` 管理页。

## 常见问题

- **构建报 `missing source directory`**：确认 GitHub 仓库根目录有 `RouterFinder/` 文件夹且里面是 `.swift` 文件；删除旧 workflow `build-ipa.yml` 的内容，用本仓库的版本覆盖。
- **Actions 里找不到 `Build jailbreak IPA`**：确认 `.github/workflows/build-ipa.yml` 已提交到仓库；也可以手动触发一次。
- **扫描结果为空**：确认本地网络权限已允许；手机和路由器在同一 Wi‑Fi；Guest 网络常开启 AP 隔离，会阻断设备间通信。
- **Filza 安装失败**：先安装 AppSync Unified；或改用其他越狱安装器。
- **想扩大扫描端口**：修改 `RouterFinder/SubnetScanner.swift` 里的 `defaultPorts`。
- **隐私说明**：所有扫描均在本机本地网络内进行，不上传任何数据，App 无服务器、无统计 SDK。
