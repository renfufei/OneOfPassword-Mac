#!/usr/bin/env bash
# build_dmg.sh — 构建 Universal Binary 并打包为 DMG
# 用法: ./scripts/build_dmg.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="OneOfPassword"
CONFIG="Release"
BUILD_DIR="$REPO_ROOT/build"

# 从 Info.plist 读取版本号
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
  "$REPO_ROOT/OneOfPassword/Info.plist")

DMG_NAME="OneOfPassword-${VERSION}-universal.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "▶ Building Universal Binary (arm64 + x86_64)  v${VERSION}"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build 2>&1 | grep -E "error:|warning:|BUILD |Signing" | grep -v "^note:"

# 找到构建产物
APP_PATH=$(xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  -showBuildSettings 2>/dev/null \
  | grep "BUILT_PRODUCTS_DIR" | head -1 | awk '{print $3}')
APP_PATH="$APP_PATH/${SCHEME}.app"

# 验证 universal binary
ARCHS_FOUND=$(lipo -info "$APP_PATH/Contents/MacOS/$SCHEME" 2>/dev/null || echo "")
echo "▶ Binary archs: $ARCHS_FOUND"

echo "▶ Creating DMG: $DMG_NAME"
mkdir -p "$BUILD_DIR"
TMP_DIR=$(mktemp -d)
trap "rm -rf '$TMP_DIR'" EXIT

cp -R "$APP_PATH" "$TMP_DIR/"
ln -s /Applications "$TMP_DIR/Applications"

# 写入安装说明
cat > "$TMP_DIR/安装说明.txt" << 'EOF'
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
  sudo xattr -dr com.apple.quarantine /Applications/OneOfPassword.app

只需操作一次，之后正常双击即可打开。


如果仍提示「文件已损坏，无法打开」
────────────────────────────────────
方法一：终端命令
  打开「终端」，粘贴以下命令后按回车：

    sudo xattr -cr /Applications/OneOfPassword.app

  然后重新双击打开应用即可。

方法二：如果以上无效，开启「任何来源」
  1. 打开「终端」，输入以下命令后按回车：

       sudo spctl --master-disable

  2. 输入 Mac 登录密码（输入时不显示字符，属正常现象）
  3. 打开「系统设置」→「隐私与安全性」
  4. 在「安全性」部分，选择「任何来源」
  5. 重新打开 OneOfPassword.app

  ⚠️ 使用完毕后建议恢复默认安全设置：
     sudo spctl --master-enable
EOF

hdiutil create \
  -volname "OneOfPassword ${VERSION}" \
  -srcfolder "$TMP_DIR" \
  -ov -format UDZO \
  "$DMG_PATH" > /dev/null

SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo "✅ Done: $DMG_PATH  ($SIZE)"
