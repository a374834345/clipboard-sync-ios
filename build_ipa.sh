#!/bin/bash
# 一键构建 IPA 脚本
# 依赖：Xcode + xcodegen
# 用法：cd 到本目录后执行 ./build_ipa.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "==> 检查依赖"

# 检查 Xcode
if ! xcrun xcodebuild -version >/dev/null 2>&1; then
    echo "❌ 未检测到 Xcode。请先从 App Store 安装 Xcode，然后执行："
    echo "   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

# 检查 xcodegen
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "==> 安装 xcodegen"
    brew install xcodegen
fi

echo "==> 生成 Xcode 工程"
xcodegen generate

echo "==> 清理旧产物"
rm -rf build Payload ClipboardSync.ipa

echo "==> 编译 (Release, iPhoneOS)"
xcodebuild \
    -project ClipboardSync.xcodeproj \
    -scheme ClipboardSync \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -sdk iphoneos \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    -derivedDataPath build \
    build

# 找到 .app
APP_PATH=$(find build/Build/Products -name "ClipboardSync.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "❌ 未找到编译产物 ClipboardSync.app"
    exit 1
fi

echo "==> 打包 IPA"
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -rq ClipboardSync.ipa Payload
rm -rf Payload

echo ""
echo "✅ 打包完成：$PROJECT_DIR/ClipboardSync.ipa"
echo ""
echo "下一步：把 ClipboardSync.ipa 传到手机，用 TrollStore 安装。"
echo "传送方式任选其一："
echo "  - AirDrop 直接发给手机"
echo "  - 放到服务器 http://124.222.192.226:55555/ 下，手机 Safari 下载"
echo "  - USB 连接用 Finder 拖入 TrollStore"
