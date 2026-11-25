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

# ── 快速重打 DMG（调布局时用）───────────────────────────────
#   DMG_ONLY=1 ./build.sh 1.79
# 跳过 xcodegen 与编译，直接用已有的 Release 产物重打 DMG。
# 微调背景图 / 图标坐标时用它，几秒出结果，不用等编译。
if [ "${DMG_ONLY:-0}" = "1" ]; then
  [ -d "$APP_PATH" ] || error "DMG_ONLY=1 但找不到已编译产物: $APP_PATH（先正常跑一次 ./build.sh）"
  info "DMG_ONLY=1  跳过编译，复用 $(basename "$APP_PATH")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
else

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

fi  # ← DMG_ONLY 分支结束

# ── Step 4: 打包 DMG（含背景图 + 图标布局）──────────────────
info "Step 4/4  打包 DMG → $DMG_NAME ..."

# 视觉参数：这里是【唯一真相】。
# 背景图由 scripts/gen_dmg_background.swift 按这组数字绘制，图标坐标由下面的
# osascript 写进 .DS_Store —— 两边同源，箭头才不会跑到图标外面。
# 改布局只改这里，别去改 Swift 里的默认值。
DMG_WIN_W=660          # 窗口内容宽（pt）
DMG_WIN_H=480          # 窗口内容高（pt），背景图就是这个尺寸
DMG_ICON_SIZE=112      # 图标尺寸（pt）
DMG_APP_X=165;  DMG_APP_Y=215   # 左：OneOfPassword.app 图标中心
DMG_APPS_X=495; DMG_APPS_Y=215   # 右：Applications 快捷方式图标中心
DMG_TXT_X=330;  DMG_TXT_Y=392   # 下：安装说明.txt 图标中心
INSTALL_TXT="安装说明.txt"

# ⚠️ 卷名必须固定，且这里的取值与 scripts/dmg/DS_Store.template 内的卷名**逐字节绑定**。
# .DS_Store 里的背景图别名记录「卷名 + 卷内相对路径」。实测（macOS 26）：
#   同名卷 + 全新镜像（创建时间、diskID 全不同）→ 解析成功，背景图正常
#   卷名不同（1.79 → 1.80）                    → 解析失败 OSStatus -43，背景图丢失
# 模板是从 Finder 亲手写出的原件上「等长字节替换」得到的（卷名 18 字节 → 18 字节），
# 这样 Bud1 容器、bplist 偏移、头部字段全都不动 —— 重建容器会让 Finder 整份忽略。
# 因此末尾的 " Disk" 不是随手加的，它是把卷名凑成 18 字节的填充。
# 想换成更短的卷名，必须让 Finder 用新卷名重新写一份 .DS_Store（见 DMG_LAYOUT=finder）。
VOL_NAME="$APP_NAME Disk"

# 预置布局模板：由一次「Finder 布局成功」的成品镜像里提取，并把别名重编码为
# 与版本无关的形态（去掉 disk_image_alias，卷名固定）。拷进 staging 即得到完整
# 布局 —— 不调用 Finder、不需要「自动化」授权，CI/无 GUI 环境同样可用。
DS_TEMPLATE="scripts/dmg/DS_Store.template"

DMG_RW="$BUILD_DIR/dmg_rw.dmg"      # 中间产物：可写镜像
MNT=""                              # 当前挂载的卷（挂到 /Volumes 下，别用自定义目录）
LAYOUT_OK=0                         # Finder 是否真的把 .DS_Store 落了盘

# 卸载卷：Finder / Spotlight 可能短暂占用，直接 -force 会把没写完的数据丢掉，
# 所以先普通卸载 + 重试，实在不行才 -force。
detach_volume() {
  local vol="$1" i
  [ -n "$vol" ] && [ -d "$vol" ] || return 0
  for i in 1 2 3 4 5; do
    hdiutil detach "$vol" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  hdiutil detach "$vol" -force >/dev/null 2>&1 || true
}

cleanup_dmg_tmp() {
  detach_volume "${MNT}"
  MNT=""
  rm -rf "$DMG_STAGING"
  rm -f "$DMG_RW"
}
trap cleanup_dmg_tmp EXIT

# 清理旧的暂存目录和同名产物
rm -rf "$DMG_STAGING"
rm -f  "$DMG_PATH" "$DMG_RW"
mkdir -p "$DMG_STAGING/.background"

cp -R "$APP_PATH" "$DMG_STAGING/"
ln -sf /Applications "$DMG_STAGING/Applications"

# 写入安装说明（对方打开 DMG 时可见）
cat > "$DMG_STAGING/$INSTALL_TXT" << 'INSTALL_EOF'
安装步骤
────────
1. 将 OneOfPassword.app 拖入右侧的 Applications（应用程序）文件夹
2. 在启动台或 Applications 文件夹中打开 OneOfPassword

首次打开提示「无法验证开发者」？
────────────────────────────────
由于应用未经 Apple 公证，macOS 会阻止直接双击打开。
解决方法（任选一种）：

方法一（推荐）：
  右键点击 OneOfPassword.app → 选择「打开」→ 点击弹窗中的「打开」

方法二（终端）：
  xattr -dr com.apple.quarantine /Applications/OneOfPassword.app

方法三（允许任何来源，需管理员密码）：
  在终端执行以下命令，开启「任何来源」安装选项：
    sudo spctl --master-disable
  执行后，系统「设置 → 隐私与安全性」中会出现「任何来源」选项，可直接双击打开本应用。
  ⚠️ 该设置对系统全局生效，用完后建议恢复默认安全策略：
    sudo spctl --master-enable

只需操作一次，之后正常双击即可打开。
INSTALL_EOF

# ── 背景图（1x + 2x 合成多分辨率 TIFF，Retina 才不糊）────────
BG_OK=1
if ! swift scripts/gen_dmg_background.swift "$DMG_STAGING/.background" \
      "$DMG_WIN_W" "$DMG_WIN_H" "$DMG_ICON_SIZE" \
      "$DMG_APP_X" "$DMG_APP_Y" "$DMG_APPS_X" "$DMG_APPS_Y" \
      "$DMG_TXT_X" "$DMG_TXT_Y" >/dev/null; then
  warn "背景图生成失败，DMG 将使用纯色背景"
  BG_OK=0
fi
if [ "$BG_OK" = "1" ] && tiffutil -cathidpicheck \
      "$DMG_STAGING/.background/background.png" \
      "$DMG_STAGING/.background/background@2x.png" \
      -out "$DMG_STAGING/.background/dmg-background.tiff" >/dev/null 2>&1; then
  rm -f "$DMG_STAGING/.background/background.png" "$DMG_STAGING/.background/background@2x.png"
  info "  背景图: ${DMG_WIN_W}×${DMG_WIN_H} @1x/@2x"
else
  warn "背景图合成失败，DMG 将使用纯色背景"
  BG_OK=0
fi

# 卷图标：让 DMG 在 Finder/桌面上显示应用自己的图标
APP_ICNS="$APP_PATH/Contents/Resources/AppIcon.icns"
[ -f "$APP_ICNS" ] && cp "$APP_ICNS" "$DMG_STAGING/.VolumeIcon.icns"

# ── 布局来源：优先用模板（零授权），没有模板才退回 Finder ─────────
# 改过 DMG_ICON_SIZE / 图标坐标后，模板里的旧数字就不对了。这时用
#   DMG_LAYOUT=finder DMG_ONLY=1 ./build.sh 1.79
# 强制走 Finder 生成一次，再用 scripts/make_ds_store_template.py 提取成新模板。
if [ "${DMG_LAYOUT:-}" = "finder" ]; then
  warn "  DMG_LAYOUT=finder：忽略模板，改用 Finder 布局（需要「自动化」授权）"
  DS_TEMPLATE=""
fi

LAYOUT_SRC="none"
if [ -f "$DS_TEMPLATE" ]; then
  # 模板里的背景图别名绑定了卷名，卷名对不上就等于没有背景图
  if strings -a "$DS_TEMPLATE" | grep -qF "$VOL_NAME"; then
    cp "$DS_TEMPLATE" "$DMG_STAGING/.DS_Store"
    LAYOUT_SRC="template"
    info "  布局: 预置 .DS_Store 模板（不调用 Finder、无需授权）"
  else
    warn "  模板里的卷名与「${VOL_NAME}」不一致，模板会失效，改用 Finder 布局兜底"
    warn "  （若改过 APP_NAME，需重新生成 $DS_TEMPLATE）"
  fi
elif [ -n "$DS_TEMPLATE" ]; then
  warn "  未找到 $DS_TEMPLATE，改用 Finder 布局（需要「自动化」授权）"
fi

# ── 可写镜像 → 挂载 → 写 Finder 布局 → 卸载 → 压回 UDZO ─────
# 直接用 hdiutil create -format UDZO 的话，镜像里没有 .DS_Store，
# 打开就是「一大排图标挤在左上角」。必须走可写镜像中转。
info "  创建可写镜像..."
hdiutil create -volname "$VOL_NAME" -srcfolder "$DMG_STAGING" \
  -fs HFS+ -format UDRW -ov -nospotlight "$DMG_RW" >/dev/null

# 【三个必须遵守的细节，违反就会出现「脚本运行时看得到、自己打开就没有」】
# 1. 挂载点必须在 /Volumes 下：Finder 写进 .DS_Store 的背景图别名记的是真实路径，
#    挂到 build/dmg_mnt 这种自定义目录，别名就指向用户打开时根本不存在的路径。
# 2. 不能加 -nobrowse：那样 Finder 不把它当可浏览卷，.DS_Store 很可能压根不写。
# 3. .DS_Store 是 Finder 异步写的，必须轮询等它出现，不能 sleep 固定秒数就卸载。
if [ -d "/Volumes/$VOL_NAME" ]; then
  warn "已有同名卷在挂载，先卸载：/Volumes/$VOL_NAME"
  diskutil unmount "/Volumes/$VOL_NAME" >/dev/null 2>&1 \
    || detach_volume "/Volumes/$VOL_NAME"
  # 残留的空挂载点目录会让下一次挂成「名字 1」，别名就指错了；空目录才删得掉
  if [ -d "/Volumes/$VOL_NAME" ] && ! mount | grep -q "on /Volumes/$VOL_NAME "; then
    rmdir "/Volumes/$VOL_NAME" 2>/dev/null || true
  fi
fi

info "  挂载可写镜像..."
MNT=""
# 模板模式加 -nobrowse：不弹 Finder 窗口，也就不会被 Finder 顺手改写模板。
# Finder 布局模式必须可浏览，否则它根本不肯写 .DS_Store。
ATTACH_ARGS="-readwrite -noverify -noautoopen"
[ "$LAYOUT_SRC" = "template" ] && ATTACH_ARGS="$ATTACH_ARGS -nobrowse"
# shellcheck disable=SC2086  # 这里就是要按空格拆成多个参数
if ATTACH_OUT=$(hdiutil attach "$DMG_RW" $ATTACH_ARGS 2>&1); then
  MNT=$(printf '%s\n' "$ATTACH_OUT" | grep -o '/Volumes/.*' | head -1)
fi
if [ -n "$MNT" ] && [ "$MNT" != "/Volumes/$VOL_NAME" ]; then
  warn "卷挂在了 $MNT（预期 /Volumes/${VOL_NAME}），背景图别名会失效"
fi

if [ -z "$MNT" ] || [ ! -d "$MNT" ]; then
  warn "可写镜像挂载失败，跳过卷图标与布局（DMG 仍会正常产出，只是排版是默认的）"
else
  # .VolumeIcon.icns 只有配上卷的「自定义图标」标记才会生效
  [ -f "$MNT/.VolumeIcon.icns" ] && SetFile -a C "$MNT" 2>/dev/null || true

  if [ "$LAYOUT_SRC" = "template" ]; then
    # 模板已带全套布局，这里一个字都不用写，只确认它确实躺进镜像了
    if [ -f "$MNT/.DS_Store" ]; then
      LAYOUT_OK=1
      info "  布局就位（.DS_Store $(stat -f%z "$MNT/.DS_Store") 字节，取自模板）"
    else
      warn "  .DS_Store 没进镜像（模板拷贝失败？），布局会退回默认排版"
    fi
  else
  # ── 兜底路径：让 Finder 摆图标并写出 .DS_Store ─────────────────
  # 【三条必须遵守的细节，违反就会出现「脚本运行时看得到、自己打开就没有」】
  # 1. 挂载点必须在 /Volumes 下：Finder 写进 .DS_Store 的背景图别名记的是真实路径，
  #    挂到 build/dmg_mnt 这种自定义目录，别名就指向用户打开时根本不存在的路径。
  # 2. 不能加 -nobrowse：那样 Finder 不把它当可浏览卷，.DS_Store 很可能压根不写。
  # 3. .DS_Store 是 Finder 异步写的，必须轮询等它出现，不能 sleep 固定秒数就卸载。
  DS_PATH="$MNT/.DS_Store"
  rm -f "$DS_PATH"   # 先删掉，免得把上一次的残留当成这次写成功

  LAYOUT_SCRIPT="$BUILD_DIR/dmg_layout.scpt"
  cat > "$LAYOUT_SCRIPT" <<APPLESCRIPT
tell application "Finder"
	tell disk "${VOL_NAME}"
		open
		delay 2
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, $((200 + DMG_WIN_W)), $((120 + DMG_WIN_H + 28))}
		set viewOptions to the icon view options of container window
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to ${DMG_ICON_SIZE}
		set text size of viewOptions to 14
		set background picture of viewOptions to file ".background:dmg-background.tiff"
		set position of item "$APP_NAME.app" of container window to {${DMG_APP_X}, ${DMG_APP_Y}}
		set position of item "Applications" of container window to {${DMG_APPS_X}, ${DMG_APPS_Y}}
		set position of item "${INSTALL_TXT}" of container window to {${DMG_TXT_X}, ${DMG_TXT_Y}}
		update without registering applications
		delay 1
		close
	end tell
end tell
APPLESCRIPT

  if osascript "$LAYOUT_SCRIPT" 2>/tmp/oop_dmg_layout.log; then
    # 关窗后轮询等 Finder 落盘，最多 10 秒
    for _ in {1..40}; do
      [ -f "$DS_PATH" ] && break
      sleep 0.25
    done
    if [ -f "$DS_PATH" ]; then
      LAYOUT_OK=1
      info "  布局已落盘（.DS_Store $(stat -f%z "$DS_PATH") 字节）"
    else
      warn "Finder 关窗后等了 10 秒仍没写出 .DS_Store —— 布局不会进镜像"
    fi
  else
    warn "Finder 布局未写入，原因见 /tmp/oop_dmg_layout.log:"
    sed 's/^/        /' /tmp/oop_dmg_layout.log | head -5
    if grep -qE '\-1743|\-10004' /tmp/oop_dmg_layout.log; then
      warn "这是「自动化权限」未授权，一次性设置即可永久生效："
      warn "  系统设置 → 隐私与安全性 → 自动化 → 勾选你运行本脚本的终端 App → 允许控制「Finder」"
    fi
  fi
  rm -f "$LAYOUT_SCRIPT"
  fi   # ← 布局来源分支（template / Finder）结束

  # 落盘后再 sync，然后卸载（内部带重试，别一上来就 -force）
  sync
  detach_volume "$MNT"
  MNT=""
fi

info "  压缩为只读镜像..."
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -ov \
  -o "$DMG_PATH" >/dev/null || error "DMG 压缩失败"

# ── 自检：重新挂载成品，确认 .DS_Store 真的进了镜像 ──────────
# 「脚本跑的时候窗口是对的、自己双击打开就变回默认」＝ 这一步没做。
# 只检查磁盘上的文件，不依赖自动化授权；能读授权时再回读一次真实视图参数。
info "  自检：重新挂载成品校验布局…"
if [ -d "/Volumes/$VOL_NAME" ]; then
  diskutil unmount "/Volumes/$VOL_NAME" >/dev/null 2>&1 || true
fi
V_MNT=""
# -nobrowse：自检不需要弹窗，也不希望 Finder 去碰只读卷
if V_OUT=$(hdiutil attach "$DMG_PATH" -readonly -noverify -noautoopen -nobrowse 2>&1); then
  V_MNT=$(printf '%s\n' "$V_OUT" | grep -o '/Volumes/.*' | head -1)
fi

if [ -z "$V_MNT" ] || [ ! -d "$V_MNT" ]; then
  warn "  成品重新挂载失败，无法自检"
elif [ ! -f "$V_MNT/.DS_Store" ]; then
  warn "  ❌ 镜像里【没有】.DS_Store —— 别人打开就是默认排版，图标全挤在左上角"
  warn "     先确认 scripts/dmg/DS_Store.template 存在且被拷进 staging；"
  warn "     若这次是 DMG_LAYOUT=finder，则需要「自动化」授权才能生成布局。"
else
  DS_FILE="$V_MNT/.DS_Store"
  info "  ✅ 镜像内含 .DS_Store（$(stat -f%z "$DS_FILE") 字节）"

  # 这两项纯文本检查不需要任何授权，但正好卡住「背景图能不能显示」：
  # 别名里必须同时包含背景图文件名与本卷卷名，卷名对不上就解析失败（-43）。
  if strings -a "$DS_FILE" | grep -qF "dmg-background.tiff"; then
    info "  ✅ 布局记录含背景图引用（dmg-background.tiff）"
  else
    warn "  ⚠️ .DS_Store 里找不到 dmg-background.tiff —— 窗口不会有背景图"
  fi
  if strings -a "$DS_FILE" | grep -qF "$VOL_NAME"; then
    info "  ✅ 别名卷名与当前卷一致（${VOL_NAME}）"
  else
    warn "  ⚠️ 别名里的卷名与「${VOL_NAME}」不一致 —— 打开后背景图会丢"
  fi

  # 有授权时回读：图标尺寸 + 背景图别名能否解析（别名断了 = 背景不显示）
  V_SCRIPT="$BUILD_DIR/dmg_verify.scpt"
  cat > "$V_SCRIPT" <<APPLESCRIPT
tell application "Finder"
	tell disk "${VOL_NAME}"
		open
		delay 1.5
		set vo to icon view options of container window
		set res to (icon size of vo)
		try
			set bgp to (background picture of vo as text)
		on error
			set bgp to "NONE"
		end try
		close container window
		return res & "|" & bgp
	end tell
end tell
APPLESCRIPT
  if V_RES=$(osascript "$V_SCRIPT" 2>/dev/null); then
    V_ICON="${V_RES%%|*}"
    V_BG="${V_RES#*|}"
    if [ "$V_ICON" = "$DMG_ICON_SIZE" ]; then
      info "  ✅ 图标尺寸 = ${V_ICON}（与脚本参数一致）"
    else
      warn "  ⚠️ 回读图标尺寸 = ${V_ICON}，预期 ${DMG_ICON_SIZE}"
    fi
    case "$V_BG" in
      *dmg-background.tiff*) info "  ✅ 背景图别名可解析" ;;
      *) warn "  ⚠️ 背景图别名解析失败（$V_BG）—— 窗口会没有背景" ;;
    esac
  else
    warn "  （无自动化授权，跳过视图参数回读；.DS_Store 在镜像里就说明布局已生效）"
  fi
  rm -f "$V_SCRIPT"
fi

if [ -n "$V_MNT" ] && [ -d "$V_MNT" ]; then
  detach_volume "$V_MNT"
fi

cleanup_dmg_tmp
trap - EXIT

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
