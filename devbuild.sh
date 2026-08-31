#!/bin/bash
# devbuild.sh — 开发调试一键脚本
# 重新生成项目 → Debug 构建 → 重置 TCC 权限 → 覆盖 /Applications → 启动
#
# 用法: ./devbuild.sh
#
# 说明：ad-hoc 签名的 Debug 构建每次 cdhash 变化，TCC 权限（截屏/辅助功能）会失效。
# 本脚本在构建后重置权限，首次运行 app 时会弹系统授权框，授权后当前二进制可用到下次重建。

set -e

PROJECT="OneOfPassword.xcodeproj"
SCHEME="OneOfPassword"
APP_NAME="OneOfPassword"
BUNDLE_ID="com.oneofpassword.app"
DERIVED_DATA="build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/${APP_NAME}.app"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# 1. 退出运行中的应用
pkill -f "${APP_NAME}.app/Contents/MacOS" 2>/dev/null || true
sleep 1

# 2. 重新生成项目（纳入新增/删除的源文件）
info "生成 Xcode 项目..."
xcodegen generate --quiet

# 3. Debug 构建
info "Debug 构建..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build > /tmp/oop_build.log 2>&1 || {
    echo "❌ 构建失败，详情见 /tmp/oop_build.log"
    grep -E "error:" /tmp/oop_build.log | head -10
    exit 1
  }

if ! grep -q "BUILD SUCCEEDED" /tmp/oop_build.log; then
  echo "❌ 构建未成功，详情见 /tmp/oop_build.log"
  grep -E "error:" /tmp/oop_build.log | head -10
  exit 1
fi
info "构建成功"

# 4. 重置 TCC 权限（避免旧条目干扰）
info "重置 TCC 权限（截屏 / 辅助功能）..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true

# 5. 清空截屏日志
rm -f "$HOME/Library/Logs/OneOfPassword-screenshot.log" 2>/dev/null || true

# 6. 覆盖到 /Applications
info "覆盖 /Applications/${APP_NAME}.app"
rm -rf "/Applications/${APP_NAME}.app"
cp -R "$APP_PATH" "/Applications/${APP_NAME}.app"

# 7. 启动
info "启动应用"
open "/Applications/${APP_NAME}.app"

echo ""
echo "✅ 完成。首次截屏会弹系统授权框，授权后即可使用。"
