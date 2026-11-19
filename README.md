# 路由器探测（RouterFinder）

一个 iOS 应用，用于发现局域网中的 DHCP 小路由器和其他网络设备，支持 **iOS 17.2 / 17.2.1 及以上**。

## 重要说明：关于"生成 IPA"

我在 Windows 环境下无法直接产出可安装的 IPA——编译需要 macOS 的 iOS SDK 和 Swift 编译器，这两样是 macOS 独占的，Windows 上无解。**但签名这一关你不用愁**：

- 你的 iPhone **已越狱** → 用 `ldid` 假签名即可，不需要任何苹果证书（见下方「越狱用户推荐方案」）；
- 云端 macOS 也能帮你编译（GitHub Actions 免费），全程不需要你买 Mac。

另外，iOS 沙箱**不允许**抓包监听 DHCP 广播（需要私有端口 67/68 或 VPN 抓包权限），所以本应用采用更可靠且完全合规的替代方案：

1. **网关推断**：读取 Wi-Fi 的 IP/掩码，推断网段网关（家庭网络中 DHCP 服务端几乎就是网关）；
2. **TCP 端口指纹**：扫描 /24 内的 80/443/8080/1900/53 等端口，识别路由器管理页与 UPnP/DNS 服务；
3. **Bonjour / mDNS**：发现局域网内宣告服务的设备。

三者结果合并，疑似路由器会排在列表最前面。

## 目录结构

```
RouterFinder/
├── project.yml                    # XcodeGen 工程定义（部署目标 iOS 17.2）
├── ExportOptions.template.plist   # 导出配置模板（自动签名）
├── ExportOptions.manual.template.plist # 导出配置模板（手动签名）
├── entitlements.plist             # ldid 假签名用的权限声明
├── build.sh                       # 打包脚本（支持自动/手动/越狱三种模式）
├── .github/workflows/build.yml    # 云端构建：ldid 假签名 IPA（越狱专用）
└── RouterFinder/                  # SwiftUI 源码
    ├── RouterFinderApp.swift
    ├── ContentView.swift
    ├── DeviceDetailView.swift
    ├── Models.swift
    ├── NetworkInfo.swift
    ├── SubnetScanner.swift
    ├── BonjourScanner.swift
    └── ScannerViewModel.swift
```

## 🍎 越狱用户推荐方案（无需证书、无需 Mac）

你的 iPhone 已越狱，这是最省事的路径。有两种方式拿到 IPA：

### 方式 1：GitHub Actions 云端构建（推荐，全程不用装 Xcode）

1. 在 GitHub 新建一个仓库（可以设为私有），把本工程整个目录推上去：
   ```bash
   cd RouterFinder
   git init && git add . && git commit -m "init"
   git remote add origin https://github.com/你的用户名/你的仓库.git
   git push -u origin main
   ```
2. 打开仓库网页 → **Actions** 标签页 → 找到 `Build jailbreak IPA` → 点 **Run workflow**；
3. 等待约 5–10 分钟，构建完成后在本次运行的页面底部 **Artifacts** 里下载 `RouterFinder-jailbroken-ipa`（需登录 GitHub 下载）；
4. 把下载到的 zip 解压得到 `RouterFinder-jailbroken.ipa`，用 AirDrop 或数据线传到手机；
5. 在手机的 **Filza** 里找到该 IPA → 点击 → 选「安装」（需先装好 **AppSync Unified** 来绕过签名校验）。

> 如果 Filza 直接安装失败，可改用其他越狱安装器（如 AppInstaller），或先装 AppSync Unified 再试。

### 方式 2：自己在 Mac 上编译

```bash
cd RouterFinder
brew install xcodegen ldid
JAILBREAK=1 ./build.sh
```

产物在 `build/ipa/RouterFinder-jailbroken.ipa`，同样用 Filza 安装。

---

## 未越狱用户的方案（需要签名）

## 方案 A：Xcode 直接装到手机（最简单，推荐先跑通）

适合有 Mac + Apple ID（不必付费）的情况，签名有效期 7 天。

1. 在 Mac 上安装 [Xcode 15.1+](https://apps.apple.com/app/xcode/id497799835) 和 XcodeGen：
   ```bash
   brew install xcodegen
   ```
2. 进入工程目录生成 Xcode 工程：
   ```bash
   cd RouterFinder
   xcodegen generate
   open RouterFinder.xcodeproj
   ```
3. 在 Xcode 中：
   - 顶部菜单 **Xcode → Settings → Accounts → +** 添加你的 Apple ID（免费即可）；
   - 选中 target `RouterFinder` → **Signing & Capabilities** → Team 选择你的个人团队（Personal Team）；
   - 把 **Bundle Identifier** 改成全局唯一的值，例如 `com.yourname.routerfinder`（免费团队的 Bundle ID 不能与任何人重复，默认那个大概率已被占用）；
   - 用数据线连接 iPhone，在手机上点「信任此电脑」，在 Xcode 设备列表选中你的手机；
   - 点 **⌘R** 运行。首次会提示「无法验证开发者」，到 iPhone **设置 → 通用 → VPN与设备管理 → 你的 Apple ID → 信任**。

4. 首次打开 App 时，系统弹窗 **「路由器探测」想查找并连接到本地网络上的设备** → 必须点**允许**，否则扫描不到任何设备。

> 注：iOS 17.2.1 是 17.2 的补丁版本，Deployment Target 设为 17.2 即可覆盖 17.2.1 及更高版本。

## 方案 B：命令行生成 IPA（免费签名）

```bash
cd RouterFinder
TEAM_ID=你的团队ID BUNDLE_ID=com.yourname.routerfinder ./build.sh
```

`TEAM_ID` 获取方式：Xcode → Settings → Accounts → 选中 Apple ID → 查看 **Team ID**（一串 10 位字母数字）。

成功后 IPA 在 `build/ipa/RouterFinder.ipa`。

## 方案 C：AltStore / Sideloadly 侧载

适合不想装 Xcode、或 IPA 来自云端构建的情况：

1. 在 Mac/Windows 上安装 [AltStore](https://altstore.io/) 或 [Sideloadly](https://sideloadly.io/)；
2. 用数据线连接 iPhone，按工具指引输入 Apple ID（建议开启两步验证并生成**应用专用密码**）；
3. 把 `RouterFinder.ipa` 拖入工具，它会自动重新签名并安装到手机；
4. 免费签名 7 天过期，到期后用同一工具刷新签名（AltStore 的 Refresh 或 Sideloadly 重新侧载）即可，数据不会丢。

> 如果你没有 Mac，可以用本仓库的 GitHub Actions：把代码推到自己的仓库，在 Actions 里手动触发 `Build unsigned IPA`，下载构建产物（未签名 IPA），再用 AltStore/Sideloadly 签名安装。

## 使用方式

1. 连接 Wi-Fi，打开 App，点「扫描局域网」；
2. 等待约 20 秒，列表按"疑似路由器优先"排序；
3. 点设备可查看开放端口、服务类型，并可一键打开 `http://设备IP` 管理页。

## 常见问题

- **扫描结果为空**：确认本地网络权限已允许；确认手机和路由器在同一 Wi-Fi；部分 Guest 网络开启了 AP 隔离，会阻断设备间通信。
- **免费签名 7 天过期**：重新用 Xcode 运行或 AltStore 刷新即可。
- **Bundle ID 冲突**：改成你自己的唯一前缀，例如 `com.sunflya.routerfinder` → `com.<你的名字>.routerfinder`。
- **想扩大扫描端口**：修改 `RouterFinder/SubnetScanner.swift` 里的 `defaultPorts`。
- **隐私说明**：所有扫描均在本机本地网络内进行，不上传任何数据，App 无网络服务器、无统计 SDK。
