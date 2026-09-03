#!/bin/bash
# build.sh — OneOfPassword Mac 打包脚本
# 用法: ./build.sh [版本号]  例如: ./build.sh 1.1
# 不传版本号时从 project.yml 中读取

set -e

# ── 配置 ────────────────────────────────────────────────────
PROJECT="OneOfPassword.xcodeproj"
SCHEME="OneOfPassword"
APP_NAME="OneOfPassword"
BUNDLE_ID="com.oneofpassword.app"
BUILD_DIR="build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
DMG_STAGING="$BUILD_DIR/dmg_staging"

# 版本号：优先使用命令行参数，否则从 project.yml 读取
if [ -n "$1" ]; then
  VERSION="$1"
else
  VERSION=$(grep 'CFBundleShortVersionString' project.yml | grep -o '"[^"]*"' | tr -d '"')
fi

if [ -z "$VERSION" ]; then
  VERSION="1.0"
fi

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
APP_PATH="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"

# ── 颜色输出 ────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 前置检查 ────────────────────────────────────────────────
info "版本: $VERSION"

[ -f "$PROJECT/project.pbxproj" ] || error "未找到 $PROJECT，请在项目根目录运行此脚本"

command -v xcodebuild  >/dev/null || error "未找到 xcodebuild，请安装 Xcode"
command -v xcodegen    >/dev/null || { warn "未找到 xcodegen，跳过项目生成步骤"; SKIP_XCODEGEN=1; }
command -v hdiutil     >/dev/null || error "未找到 hdiutil"

# ── Step 1: 生成 Xcode 项目 ─────────────────────────────────
if [ -z "$SKIP_XCODEGEN" ]; then
  info "Step 1/4  生成 Xcode 项目..."
  xcodegen generate --quiet
else
  info "Step 1/4  跳过 xcodegen"
fi

# ── Step 2: 更新版本号 ──────────────────────────────────────
info "Step 2/4  更新版本号 → $VERSION ..."
# 用 xcodebuild 直接覆盖 plist 中的版本字段（避免依赖 PlistBuddy 路径问题）
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  "$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app/Contents/Info.plist" 2>/dev/null || true

# ── Step 3: Release 编译 ────────────────────────────────────
info "Step 3/4  Release 编译..."
rm -rf "$DERIVED_DATA"

BUILD_LOG="$BUILD_DIR/build.log"
mkdir -p "$BUILD_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  CURRENT_PROJECT_VERSION="$VERSION" \
  MARKETING_VERSION="$VERSION" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  2>&1 | tee "$BUILD_LOG" | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

[ -d "$APP_PATH" ] || error "编译失败，详情见 $BUILD_LOG"

# 写入版本号到 .app 内的 Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || true

info "  签名信息:"
codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" | sed 's/^/    /'

# ── Step 4: 打包 DMG ────────────────────────────────────────
info "Step 4/4  打包 DMG → $DMG_NAME ..."

# 清理旧的暂存目录和同名 DMG
rm -rf "$DMG_STAGING"
rm -f  "$DMG_PATH"
mkdir -p "$DMG_STAGING"

cp -R "$APP_PATH" "$DMG_STAGING/"
ln -sf /Applications "$DMG_STAGING/Applications"

# 写入安装说明（对方打开 DMG 时可见）
cat > "$DMG_STAGING/安装说明.txt" << 'INSTALL_EOF'
安装步骤
────────
1. 将 OneOfPassword.app 拖入右侧的 Applications（应用程序）文件夹
2. 在启动台或 Applications 文件夹中打开 OneOfPassword

首次打开提示「无法验证开发者」？
────────────────────────────────
由于应用未经 Apple 公证，macOS 会阻止直接双击打开。
解决方法（两种任选一种）：

方法一（推荐）：
  右键点击 OneOfPassword.app → 选择「打开」→ 点击弹窗中的「打开」

方法二（终端）：
  xattr -dr com.apple.quarantine /Applications/OneOfPassword.app

只需操作一次，之后正常双击即可打开。
INSTALL_EOF

hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH" \
  2>&1 | grep -v "^created:" || true

rm -rf "$DMG_STAGING"

# ── 完成 ────────────────────────────────────────────────────
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
APP_SIZE=$(du -sh "$APP_PATH"  | cut -f1)

echo ""
echo -e "${GREEN}✅ 打包完成${NC}"
echo "   .app  $APP_SIZE   $APP_PATH"
echo "   .dmg  $DMG_SIZE   $DMG_PATH"
echo ""
echo "分发给他人时，对方首次打开需要："
echo "  右键 → 打开 → 点击「打开」（绕过 Gatekeeper）"
echo ""

# 在 Finder 中高亮显示 DMG
open -R "$DMG_PATH"
