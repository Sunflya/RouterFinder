#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RouterFinder IPA 打包脚本（必须在 macOS 上运行）
#
# 【模式 C：越狱设备，无需证书】
#   JAILBREAK=1 ./build.sh
#   产物：build/ipa/RouterFinder-jailbroken.ipa
#
# 【模式 A：自动签名】
#   TEAM_ID=你的团队ID BUNDLE_ID=com.yourname.routerfinder METHOD=ad-hoc ./build.sh
#
# 【模式 B：手动签名】
#   P12_PATH=~/证书.p12 P12_PASSWORD=证书密码 PROFILE_PATH=~/描述文件.mobileprovision \
#   BUNDLE_ID=com.yourname.routerfinder METHOD=ad-hoc ./build.sh
#
# METHOD: development / ad-hoc / app-store（默认 ad-hoc）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="RouterFinder.xcodeproj"
SCHEME="RouterFinder"
BUILD_DIR="$SCRIPT_DIR/build"
BUNDLE_ID="${BUNDLE_ID:-com.sunflya.routerfinder}"
METHOD="${METHOD:-ad-hoc}"

usage() {
  cat <<'EOF'
用法：
  JAILBREAK=1 ./build.sh                         # 越狱 IPA（ldid 假签名，推荐）
  TEAM_ID=XXXXXXXXXX ./build.sh                  # 自动签名
  P12_PATH=a.p12 P12_PASSWORD=pwd PROFILE_PATH=a.mobileprovision ./build.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$BUILD_DIR"

# ---------- 源码结构检查 ----------
if [[ ! -d "$SCRIPT_DIR/RouterFinder" || ! -f "$SCRIPT_DIR/RouterFinder/RouterFinderApp.swift" ]]; then
  echo "错误: 找不到 $SCRIPT_DIR/RouterFinder 源码目录。" >&2
  echo "请确认 SwiftUI 源码文件夹 RouterFinder/ 已随工程一起上传，且路径为仓库根目录下的 RouterFinder/。" >&2
  exit 1
fi

# ---------- 参数检查 ----------
if [[ "${JAILBREAK:-0}" == "1" ]]; then
  MODE="jailbreak"
elif [[ -n "${P12_PATH:-}" && -n "${PROFILE_PATH:-}" ]]; then
  MODE="manual"
  [[ -f "$P12_PATH" ]] || { echo "找不到 p12 文件: $P12_PATH" >&2; exit 1; }
  [[ -f "$PROFILE_PATH" ]] || { echo "找不到描述文件: $PROFILE_PATH" >&2; exit 1; }
  [[ -n "${P12_PASSWORD:-}" ]] || { echo "手动签名需要设置 P12_PASSWORD" >&2; exit 1; }
elif [[ -n "${TEAM_ID:-}" ]]; then
  MODE="automatic"
else
  echo "请设置签名参数：" >&2
  usage >&2
  exit 1
fi

if [[ "$BUNDLE_ID" == "com.sunflya.routerfinder" ]]; then
  echo "提示: 正在使用默认 Bundle ID $BUNDLE_ID（越狱模式无影响；上架/侧载建议改成唯一值）" >&2
fi

echo "[环境] $(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null || true)"
xcodebuild -version | head -n 2

# ---------- 手动签名准备 ----------
CERT_NAME=""
P_UUID=""
P_TEAM_ID=""
PROFILE_NAME=""
if [[ "$MODE" == "manual" ]]; then
  echo "[准备] 导入 p12 证书到钥匙串…"
  KEYCHAIN="${SIGNING_KEYCHAIN:-login.keychain-db}"
  security import "$P12_PATH" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null || true

  CERT_NAME="$(
    openssl pkcs12 -in "$P12_PATH" -nodes -passin pass:"$P12_PASSWORD" -clcerts 2>/dev/null \
      | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
      | sed -E 's/^subject=CN=([^,]+).*/\1/' \
      | head -n 1
  )"
  if [[ -z "${CERT_NAME:-}" && -n "${CERT_NAME_OVERRIDE:-}" ]]; then
    CERT_NAME="$CERT_NAME_OVERRIDE"
  fi
  [[ -n "$CERT_NAME" ]] || { echo "无法从 p12 提取证书名称，请设置 CERT_NAME_OVERRIDE" >&2; exit 1; }
  echo "  证书名称: $CERT_NAME"

  echo "[准备] 安装描述文件…"
  PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$PROFILES_DIR"
  cp "$PROFILE_PATH" "$PROFILES_DIR/"

  PROFILE_PLIST="$BUILD_DIR/profile.plist"
  security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"

  P_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
  P_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST")"
  PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")"
  P_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST" | sed -E 's/^[A-Z0-9]+\.//')"

  echo "  描述文件 Team ID: $P_TEAM_ID"
  echo "  描述文件 Bundle ID: $P_APP_ID"

  if [[ -n "$P_APP_ID" && "$P_APP_ID" != "$BUNDLE_ID" && "$P_APP_ID" != "*" ]]; then
    echo "警告: 描述文件 Bundle ID ($P_APP_ID) 与 BUNDLE_ID ($BUNDLE_ID) 不一致，可能签名失败" >&2
  fi
  TEAM_ID="${TEAM_ID:-$P_TEAM_ID}"
fi

# ---------- 生成 Xcode 工程 ----------
echo "[1/4] 生成 Xcode 工程…"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec project.yml
else
  echo "未安装 XcodeGen，请先执行: brew install xcodegen" >&2
  exit 1
fi
plutil -lint Info.plist >/dev/null

# ---------- 越狱模式：无签名编译 + ldid 假签名 ----------
if [[ "$MODE" == "jailbreak" ]]; then
  echo "[2/4] 无签名编译（Bundle ID: $BUNDLE_ID）…"
  command -v ldid >/dev/null 2>&1 || { echo "未安装 ldid，请先执行: brew install ldid" >&2; exit 1; }

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    clean build

  echo "[3/4] ldid 假签名并打包 IPA…"
  APP="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/RouterFinder.app"
  [[ -d "$APP" ]] || { echo "找不到编译产物: $APP" >&2; exit 1; }

  # 从 Info.plist 读取真实可执行文件名，避免 PRODUCT_NAME 被改动后脚本失效
  APP_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null || echo RouterFinder)"
  APP_BIN="$APP/$APP_EXEC"
  [[ -f "$APP_BIN" ]] || { echo "找不到主可执行文件: $APP_BIN" >&2; exit 1; }

  sed "s|com.sunflya.routerfinder|$BUNDLE_ID|g" entitlements.plist > "$BUILD_DIR/entitlements-jb.plist"
  plutil -lint "$BUILD_DIR/entitlements-jb.plist" >/dev/null
  ENTITLEMENTS="$BUILD_DIR/entitlements-jb.plist"

  IPA_ROOT="$BUILD_DIR/ipa"
  rm -rf "$IPA_ROOT/Payload"
  mkdir -p "$IPA_ROOT/Payload"
  cp -R "$APP" "$IPA_ROOT/Payload/"

  ldid -S"$ENTITLEMENTS" "$IPA_ROOT/Payload/RouterFinder.app/$APP_EXEC"

  # 对 app 内所有 Mach-O（扩展、Framework、dylib）都假签名
  while IFS= read -r -d '' f; do
    if file "$f" | grep -q "Mach-O"; then
      ldid -S"$ENTITLEMENTS" "$f"
    fi
  done < <(find "$IPA_ROOT/Payload/RouterFinder.app" -type f -print0)

  echo "[4/4] 生成 IPA 与校验和…"
  IPA="$IPA_ROOT/RouterFinder-jailbroken.ipa"
  rm -f "$IPA" "$IPA.sha256"
  (cd "$IPA_ROOT" && zip -qry RouterFinder-jailbroken.ipa Payload -x '*.DS_Store' -x '__MACOSX/*')
  shasum -a 256 "$IPA" | awk '{print $1}' > "$IPA.sha256"

  echo ""
  echo "完成！IPA: $IPA"
  echo "SHA256: $(cat "$IPA.sha256")"
  echo "安装：Filza 打开 IPA → 安装（需已装 AppSync Unified）"
  exit 0
fi

# ---------- 生成导出配置 ----------
echo "[2/4] 生成导出配置（method=$METHOD）…"
if [[ "$MODE" == "manual" ]]; then
  sed \
    -e "s/__METHOD__/$METHOD/g" \
    -e "s/__TEAM_ID__/$TEAM_ID/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__PROFILE_NAME__/$PROFILE_NAME/g" \
    ExportOptions.manual.template.plist > ExportOptions.plist
else
  sed \
    -e "s/__METHOD__/$METHOD/g" \
    -e "s/__TEAM_ID__/$TEAM_ID/g" \
    ExportOptions.template.plist > ExportOptions.plist
fi
plutil -lint ExportOptions.plist >/dev/null

# ---------- 归档 ----------
echo "[3/4] 归档（模式=$MODE）…"
ARCHIVE_CMD=(
  xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=iOS"
  -archivePath "$BUILD_DIR/RouterFinder.xcarchive"
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  DEVELOPMENT_TEAM="$TEAM_ID"
)

if [[ "$MODE" == "manual" ]]; then
  ARCHIVE_CMD+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$CERT_NAME"
    PROVISIONING_PROFILE_SPECIFIER="$P_UUID"
  )
else
  ARCHIVE_CMD+=(CODE_SIGN_STYLE=Automatic)
fi

"${ARCHIVE_CMD[@]}" clean archive

# ---------- 导出 ----------
echo "[4/4] 导出 IPA…"
rm -rf "$BUILD_DIR/ipa"
mkdir -p "$BUILD_DIR/ipa"
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/RouterFinder.xcarchive" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$BUILD_DIR/ipa"

IPA="$(find "$BUILD_DIR/ipa" -maxdepth 1 -name '*.ipa' -print -quit)"
[[ -n "$IPA" ]] || { echo "导出完成但找不到 IPA 文件" >&2; exit 1; }
shasum -a 256 "$IPA" | awk '{print $1}' > "$IPA.sha256"

echo ""
echo "完成！IPA: $IPA"
echo "SHA256: $(cat "$IPA.sha256")"
echo "可用 AltStore / Sideloadly / 爱思助手 安装到 iPhone"
