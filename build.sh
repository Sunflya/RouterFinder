#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RouterFinder IPA 打包脚本
#
# 三种模式，三选一：
#
# 【模式 A：自动签名】（推荐，Xcode 自动管理证书和描述文件）
#   TEAM_ID=你的团队ID BUNDLE_ID=com.yourname.routerfinder METHOD=ad-hoc ./build.sh
#
# 【模式 B：手动签名】（使用已有的 p12 证书 + mobileprovision 描述文件）
#   P12_PATH=~/证书.p12 P12_PASSWORD=证书密码 PROFILE_PATH=~/描述文件.mobileprovision \
#   BUNDLE_ID=com.yourname.routerfinder METHOD=ad-hoc ./build.sh
#
# 【模式 C：越狱设备】（无需任何证书，ldid 假签名）
#   JAILBREAK=1 ./build.sh
#
# METHOD 可选：
#   development - 开发签名，需注册设备 UDID，适合 Xcode 直装调试
#   ad-hoc      - Ad Hoc 分发，需注册设备 UDID，适合 AltStore/Sideloadly 侧载（默认）
#   app-store   - App Store 分发，用于上架（普通用户用不到）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="RouterFinder.xcodeproj"
SCHEME="RouterFinder"
BUILD_DIR="$SCRIPT_DIR/build"
BUNDLE_ID="${BUNDLE_ID:-com.sunflya.routerfinder}"
METHOD="${METHOD:-ad-hoc}"

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
  echo "  自动签名: TEAM_ID=你的团队ID ./build.sh" >&2
  echo "  手动签名: P12_PATH=xxx P12_PASSWORD=xxx PROFILE_PATH=xxx ./build.sh" >&2
  echo "  越狱设备: JAILBREAK=1 ./build.sh" >&2
  exit 1
fi

if [[ "$BUNDLE_ID" == "com.sunflya.routerfinder" ]]; then
  echo "警告: 正在使用默认 Bundle ID，建议用 BUNDLE_ID=com.你的名字.routerfinder 覆盖" >&2
fi

# ---------- 模式 B 准备：导入证书和描述文件 ----------
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
  [[ -n "$CERT_NAME" ]] || { echo "无法从 p12 提取证书名称，请手动设置 CERT_NAME=证书名称" >&2; exit 1; }
  echo "  证书名称: $CERT_NAME"

  echo "[准备] 安装描述文件…"
  PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$PROFILES_DIR"
  cp "$PROFILE_PATH" "$PROFILES_DIR/"

  PROFILE_PLIST="$BUILD_DIR/profile.plist"
  mkdir -p "$BUILD_DIR"
  security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"

  P_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
  P_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST")"
  PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")"
  P_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST" | sed -E 's/^[A-Z0-9]+\.//')"

  echo "  描述文件 Team ID: $P_TEAM_ID"
  echo "  描述文件 Bundle ID: $P_APP_ID"

  if [[ -n "$P_APP_ID" && "$P_APP_ID" != "$BUNDLE_ID" && "$P_APP_ID" != "*" ]]; then
    echo "警告: 描述文件的 Bundle ID ($P_APP_ID) 与 BUNDLE_ID ($BUNDLE_ID) 不一致，可能导致签名失败" >&2
  fi

  TEAM_ID="${TEAM_ID:-$P_TEAM_ID}"
fi

# ---------- 生成工程 ----------
echo "[1/4] 生成 Xcode 工程…"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec project.yml
else
  echo "未安装 XcodeGen，请先执行: brew install xcodegen" >&2
  exit 1
fi

# ---------- 越狱模式：无签名编译 + ldid 假签名 ----------
if [[ "$MODE" == "jailbreak" ]]; then
  echo "[3/4] 无签名编译…"
  command -v ldid >/dev/null 2>&1 || { echo "未安装 ldid，请先执行: brew install ldid" >&2; exit 1; }

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    clean build

  echo "[4/4] ldid 假签名并打包 IPA…"
  APP="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/RouterFinder.app"
  [[ -d "$APP" ]] || { echo "找不到编译产物: $APP" >&2; exit 1; }

  # 让 entitlements 里的 Bundle ID 跟随实际包名
  sed "s|com.sunflya.routerfinder|$BUNDLE_ID|g" entitlements.plist > "$BUILD_DIR/entitlements-jb.plist"
  ENTITLEMENTS="$BUILD_DIR/entitlements-jb.plist"

  mkdir -p "$BUILD_DIR/ipa/Payload"
  rm -rf "$BUILD_DIR/ipa/Payload/RouterFinder.app"
  cp -R "$APP" "$BUILD_DIR/ipa/Payload/"

  ldid -S"$ENTITLEMENTS" "$BUILD_DIR/ipa/Payload/RouterFinder.app/RouterFinder"
  while IFS= read -r -d '' f; do
    if file "$f" | grep -q "Mach-O"; then
      ldid -S"$ENTITLEMENTS" "$f"
    fi
  done < <(find "$BUILD_DIR/ipa/Payload/RouterFinder.app" -type f -print0)

  (cd "$BUILD_DIR/ipa" && rm -f RouterFinder-jailbroken.ipa && zip -qry RouterFinder-jailbroken.ipa Payload)

  echo ""
  echo "完成！IPA 位于: $BUILD_DIR/ipa/RouterFinder-jailbroken.ipa"
  echo "用 Filza 找到该文件，点击安装（需已安装 AppSync Unified）"
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
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/RouterFinder.xcarchive" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$BUILD_DIR/ipa"

echo ""
echo "完成！IPA 位于: $BUILD_DIR/ipa/RouterFinder.ipa"
echo "可用 AltStore / Sideloadly / 爱思助手 安装到 iPhone"
