#!/bin/bash
# release.sh — 把 DMG 产物发布到 GitHub Releases
#
# 用法:
#   ./release.sh                     版本号取 project.yml，DMG 缺失时自动构建
#   ./release.sh 1.72                指定版本号
#   ./release.sh 1.72 --draft        发为草稿（到网页确认后再 Publish）
#   ./release.sh 1.72 --dry-run      只打印将要执行的命令，不改远端
#   ./release.sh --help              查看全部选项
#
# 两条通道（自动选择，无需干预）:
#   A. 有 gh  → gh release create / upload（最省事，认证由 gh auth login 管）
#   B. 无 gh  → GitHub REST API + curl，需要环境变量 GH_TOKEN 或 GITHUB_TOKEN
#               （classic PAT 勾 repo，或 fine-grained 勾 Contents: Write）
#
# 依赖: 必需 git / curl（macOS 自带）；可选 gh
#
# 注意: 变量一律写成 ${VAR} 而不是 $VAR —— bash 3.2 在 UTF-8 下会把紧跟其后的
#       全角标点（如「（」）的字节吞进变量名，报 unbound variable。
#
# 网络: gh 与 curl 都【不读 macOS 的「系统代理」设置】，只认 HTTP(S)_PROXY 环境变量。
#       而 GitHub 在国内网络下 https://github.com 直连常常超时（SSH 反而通）。
#       所以脚本会自动探测本地代理端口并临时启用，见 setup_proxy()。

set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────
APP_NAME="OneOfPassword"
BUILD_DIR="build"
TAG_PREFIX="v"

# 常见本地代理端口（Clash / Surge / V2Ray / Privoxy…），按命中概率排
PROXY_PORTS="7897 7890 7891 7899 1087 1086 1080 8118 8888 6152 33210 2080"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "${BLUE}▶${NC} $*"; }

# 探针：只取 HTTP 状态码，连通失败返回 000。
# 【不要用 curl -f】—— api.github.com 未认证时会回 403，那是「通」而不是「不通」；
# -f 会把 403/5xx 当成失败，导致明明直连可用却去启用代理。
http_code() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$1" 2>/dev/null) || true
  [ -n "${code}" ] || code=000
  printf '%s' "${code}"
}

# 让 gh / curl 走得上网。
# 这不是「顺手加一层」，而是必需：gh 是 Go 程序，只读标准代理环境变量；
# curl 同理。macOS 的「系统代理」只对 AppKit/CFNetwork 系（浏览器）生效。
setup_proxy() {
  if [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]; then
    info "沿用已有代理: ${HTTPS_PROXY:-${https_proxy:-}}"
    return 0
  fi
  local gh_code api_code direct_ok=1
  gh_code=$(http_code "https://github.com")
  api_code=$(http_code "https://api.github.com")
  # 000 = 连不上；502/503/504 = 被拦路设备（透明代理 / 网关）顶回来的伪响应。
  # 那种情况下确实「收到了 HTTP 响应」，但根本到不了 GitHub，不能算通。
  case "${gh_code}"  in 000|502|503|504) direct_ok=0 ;; esac
  case "${api_code}" in 000|502|503|504) direct_ok=0 ;; esac
  if [ "${direct_ok}" = "1" ]; then
    info "GitHub 直连可用（github.com=${gh_code}, api=${api_code}），不使用代理"
    return 0
  fi
  warn "GitHub 直连不通（github.com=${gh_code}, api=${api_code}），尝试探测本地代理…"
  local port code
  for port in ${PROXY_PORTS}; do
    nc -z -w 1 127.0.0.1 "${port}" 2>/dev/null || continue
    export HTTPS_PROXY="http://127.0.0.1:${port}"
    export HTTP_PROXY="${HTTPS_PROXY}"
    export NO_PROXY="127.0.0.1,localhost,::1"
    code=$(http_code "https://github.com")
    # 代理这条路要严一点：2xx/3xx 才算真通（坏代理/节点不通会回 502）
    case "${code}" in
      2*|3*) info "已启用本地代理 ${HTTPS_PROXY}（仅本次运行有效，github.com=${code}）"
             return 0 ;;
    esac
    unset HTTPS_PROXY HTTP_PROXY NO_PROXY
  done
  warn "未找到可用的本地代理。若 GitHub 需要代理，请手动指定，例如:"
  warn "  export HTTPS_PROXY=http://127.0.0.1:7897   # 换成你的代理端口"
  return 0
}

usage() {
  cat <<'USAGE'
release.sh — 把 DMG 产物发布到 GitHub Releases

用法:
  ./release.sh                     版本号取 project.yml，DMG 缺失时自动构建
  ./release.sh 1.72                指定版本号
  ./release.sh 1.72 --draft        发为草稿（到网页确认后再 Publish）
  ./release.sh 1.72 --dry-run      只打印将要执行的命令，不改远端
  ./release.sh --help              查看帮助

选项:
  -t, --title <标题>       发布标题（默认用 tag 名）
  -n, --notes <文本>       release 说明（默认自动收集上次 tag 以来的提交）
  -f, --notes-file <文件>  从文件读取 release 说明
      --no-tag             不创建/推送 git tag（tag 已存在时用）
      --draft              发布为草稿
      --prerelease         标记为预发布
      --skip-build         DMG 不存在时不自动构建（直接报错）
      --dry-run            只打印，不改远端
  -h, --help               显示本帮助

两条通道（自动选择）:
  A. 有 gh  → gh release create / upload，认证由 gh auth login 管理（推荐）
  B. 无 gh  → GitHub REST API + curl，需要 GH_TOKEN 或 GITHUB_TOKEN 环境变量
              （classic PAT 勾 repo，或 fine-grained 勾 Contents: Write）

重复执行是安全的: 已存在的 tag / release 会被复用，同名附件会被覆盖。
USAGE
  exit 0
}

# ── 参数解析 ────────────────────────────────────────────────
VERSION=""; TITLE=""; NOTES=""; NOTES_FILE=""
DRAFT=false; PRERELEASE=false; PUSH_TAG=true; SKIP_BUILD=false; DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--title)      TITLE="${2:-}";        shift 2 ;;
    -n|--notes)      NOTES="${2:-}";        shift 2 ;;
    -f|--notes-file) NOTES_FILE="${2:-}";   shift 2 ;;
    --no-tag)        PUSH_TAG=false;        shift ;;
    --draft)         DRAFT=true;            shift ;;
    --prerelease)    PRERELEASE=true;       shift ;;
    --skip-build)    SKIP_BUILD=true;       shift ;;
    --dry-run)       DRY_RUN=true;          shift ;;
    -h|--help)       usage ;;
    -*)              error "未知选项: ${1}（用 --help 查看用法）" ;;
    *)               [ -z "${VERSION}" ] || error "版本号只能给一个（已收到 ${VERSION}，又来了 ${1}）"
                     VERSION="$1";          shift ;;
  esac
done

# 必须在仓库根目录运行
[ -d .git ]        || error "当前目录不是 git 仓库根目录"
[ -f project.yml ] || error "未找到 project.yml，请在项目根目录运行"

# ── 版本号 ──────────────────────────────────────────────────
if [ -z "${VERSION}" ]; then
  VERSION=$(grep 'CFBundleShortVersionString' project.yml | head -1 | grep -o '"[^"]*"' | tr -d '"')
  [ -n "${VERSION}" ] || error "无法从 project.yml 读取版本号，请显式传入，例如 ./release.sh 1.72"
  info "从 project.yml 读取版本号: ${VERSION}"
fi
TAG="${TAG_PREFIX}${VERSION}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

# ── 仓库 slug ───────────────────────────────────────────────
REMOTE_URL=$(git remote get-url origin 2>/dev/null) || error "未配置 origin 远程仓库"
REPO_SLUG=$(echo "${REMOTE_URL}" | sed -E 's#^(git@|https://|ssh://git@)github\.com[:/]##; s#\.git$##')
case "${REPO_SLUG}" in */*) ;; *) error "无法从 remote 解析 owner/repo: ${REMOTE_URL}" ;; esac
info "目标仓库: ${REPO_SLUG}    tag: ${TAG}"

# ── 1. 准备 DMG ─────────────────────────────────────────────
step "1/5  准备 DMG 产物"
if [ -s "${DMG_PATH}" ]; then
  info "已存在: ${DMG_PATH}（$(du -h "${DMG_PATH}" | cut -f1)）"
else
  [ "${SKIP_BUILD}" = false ] || error "DMG 不存在且指定了 --skip-build: ${DMG_PATH}"
  warn "未找到 ${DMG_PATH}，调用 ./build.sh ${VERSION} 构建…"
  if [ "${DRY_RUN}" = true ]; then
    info "[dry-run] ./build.sh ${VERSION}"
  else
    ./build.sh "${VERSION}"
  fi
fi
if [ "${DRY_RUN}" = false ] && [ ! -s "${DMG_PATH}" ]; then
  error "DMG 不存在或为空: ${DMG_PATH}"
fi

# ── 2. git 前置检查 ─────────────────────────────────────────
step "2/5  检查 git 状态"
DIRTY=0
if [ -n "$(git status --porcelain)" ]; then
  DIRTY=1
  warn "工作区有未提交改动 —— tag 指向 HEAD，这些改动不会进 release："
  git status --short | sed 's/^/        /'
fi
if git rev-parse --verify --quiet "refs/remotes/origin/HEAD" >/dev/null 2>&1; then
  AHEAD=$(git rev-list --count "origin/HEAD..HEAD" 2>/dev/null || echo 0)
  [ "${AHEAD}" = "0" ] || warn "本地领先 origin/HEAD ${AHEAD} 个提交，release 前建议先 git push"
fi

# ── 3. tag ──────────────────────────────────────────────────
step "3/5  创建并推送 tag"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  info "tag ${TAG} 已存在（复用）"
elif [ "${PUSH_TAG}" = false ]; then
  warn "指定了 --no-tag 但 tag ${TAG} 不存在，release 可能因找不到 tag 而失败"
elif [ "${DRY_RUN}" = true ]; then
  info "[dry-run] git tag -a ${TAG} -m \"Release ${VERSION}\" && git push origin ${TAG}"
else
  git tag -a "${TAG}" -m "Release ${VERSION}"
  git push origin "${TAG}"
  info "已推送 tag ${TAG}"
fi

# ── 4. 组装发布文案 ─────────────────────────────────────────
step "4/5  组装发布说明"
if [ -n "${NOTES_FILE}" ]; then
  [ -f "${NOTES_FILE}" ] || error "说明文件不存在: ${NOTES_FILE}"
  NOTES=$(cat "${NOTES_FILE}")
  info "说明来自文件: ${NOTES_FILE}"
elif [ -z "${NOTES}" ]; then
  PREV_TAG=$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)
  if [ -n "${PREV_TAG}" ]; then
    RANGE="${PREV_TAG}..HEAD"
    RANGE_DESC="上次发布以来的提交（${PREV_TAG}..HEAD）"
  else
    RANGE="$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)..HEAD"
    RANGE_DESC="仓库全部提交（还没有历史 tag）"
  fi
  NOTES=$(git log --no-merges --pretty=format:'- %s' "${RANGE}" 2>/dev/null || true)
  [ -n "${NOTES}" ] || NOTES="- 本次发布无提交记录"
  info "发布说明来自：${RANGE_DESC}"
fi

NOTES=$(printf '%s\n\n---\n\n**安装**：下载 `%s`，拖入 Applications。首次打开若提示「无法验证开发者」，右键 → 打开 → 打开，或执行 `xattr -dr com.apple.quarantine /Applications/%s.app`。\n' \
  "${NOTES}" "${DMG_NAME}" "${APP_NAME}")

[ -n "${TITLE}" ] || TITLE="${TAG}"

# ── 5. 发布 ─────────────────────────────────────────────────
step "5/5  发布到 GitHub Releases"
setup_proxy

if command -v gh >/dev/null 2>&1; then
  info "通道 A: gh CLI"
  GH_FLAGS=""
  [ "${DRAFT}" = true ]      && GH_FLAGS="${GH_FLAGS} --draft"
  [ "${PRERELEASE}" = true ] && GH_FLAGS="${GH_FLAGS} --prerelease"
  if [ "${DRY_RUN}" = true ]; then
    info "[dry-run] gh release create ${TAG} \"${DMG_PATH}\" --title \"${TITLE}\" --notes \"<见上>\"${GH_FLAGS}"
  elif gh release view "${TAG}" >/dev/null 2>&1; then
    warn "release ${TAG} 已存在，改为上传 / 覆盖附件"
    # shellcheck disable=SC2086
    gh release upload "${TAG}" "${DMG_PATH}" --clobber ${GH_FLAGS}
  else
    # shellcheck disable=SC2086
    gh release create "${TAG}" "${DMG_PATH}" --title "${TITLE}" --notes "${NOTES}" ${GH_FLAGS}
  fi
else
  info "通道 B: GitHub REST API + curl（未检测到 gh）"
  TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

  if [ "${DRY_RUN}" = true ]; then
    API="https://api.github.com/repos/${REPO_SLUG}"
    info "[dry-run] POST ${API}/releases        (tag=${TAG}, draft=${DRAFT}, prerelease=${PRERELEASE})"
    info "[dry-run] POST https://uploads.github.com/repos/${REPO_SLUG}/releases/<id>/assets?name=${DMG_NAME}"
    [ -n "${TOKEN}" ] || warn "未设置 GH_TOKEN / GITHUB_TOKEN —— 真正执行时会在这里报错"
  else
    [ -n "${TOKEN}" ] || error "缺少访问令牌。二选一：
        · 装 gh 最省事：brew install gh && gh auth login
        · 或导出令牌：export GH_TOKEN=<personal-access-token>（需 repo / Contents 写权限）"

    API="https://api.github.com/repos/${REPO_SLUG}"
    AUTH=(-H "Authorization: Bearer ${TOKEN}"
          -H "Accept: application/vnd.github+json"
          -H "X-GitHub-Api-Version: 2022-11-28")

    # JSON 字符串转义，返回【不含外层引号】的转义内容（调用处自己补引号）。
    # 优先 python3（json.dumps 天然正确）；纯 awk 回退时不用 gsub 替换串 ——
    # 「\ 后跟非 & 非 \」在 POSIX 里是未定义行为，macOS awk 会把 \t 输成字面 \\t。
    json_str() {
      if [ -x /usr/bin/python3 ]; then
        /usr/bin/python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])'
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])'
      else
        sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g' |
          awk -v bs='\\' '
            { if (NR > 1) printf "%s%s", bs, "n"
              n = split($0, p, "\t")
              for (i = 1; i <= n; i++) { if (i > 1) printf "%s%s", bs, "t"; printf "%s", p[i] }
            }'
      fi
    }
    TITLE_J=$(printf '%s' "${TITLE}" | json_str)
    NOTES_J=$(printf '%s' "${NOTES}" | json_str)
    # tag_name 来自 project.yml 或命令行，只含版本字符，无需转义
    BODY=$(printf '{"tag_name":"%s","name":"%s","body":"%s","draft":%s,"prerelease":%s}' \
      "${TAG}" "${TITLE_J}" "${NOTES_J}" "${DRAFT}" "${PRERELEASE}")

    # 已存在则复用，保证脚本可重复执行
    RELEASE_JSON=$(curl -sfS -X GET "${API}/releases/tags/${TAG}" "${AUTH[@]}" 2>/dev/null || true)
    if [ -z "${RELEASE_JSON}" ]; then
      RELEASE_JSON=$(curl -sfS -X POST "${API}/releases" "${AUTH[@]}" \
        -H "Content-Type: application/json" -d "${BODY}") \
        || error "创建 release 失败（检查令牌权限、tag 是否已推送）"
      info "已创建 release ${TAG}"
    else
      warn "release ${TAG} 已存在，复用并覆盖同名附件"
    fi

    # GitHub 返回的是带缩进的格式化 JSON —— 必须先压平再取字段，
    # 否则 '"id":123' 这种无空格模式根本匹配不上（实际是 '"id": 123'）。
    # release 的 "id" 排在作者信息之前，所以第一个就是 release id。
    RELEASE_ID=$(printf '%s' "${RELEASE_JSON}" | tr -d '\n ' \
      | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)
    [ -n "${RELEASE_ID}" ] || error "无法解析 release id"

    # 同名附件先删后传，避免 422 already_exists。
    # 同样要先压平：格式化 JSON 里 id 与 name 不在同一行，按行切分只会各取到一半。
    OLD_ASSET_ID=$(curl -sfS "${API}/releases/${RELEASE_ID}/assets" "${AUTH[@]}" 2>/dev/null \
      | tr -d '\n ' | tr '{' '\n' | grep -F "\"name\":\"${DMG_NAME}\"" \
      | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2 || true)
    if [ -n "${OLD_ASSET_ID:-}" ]; then
      curl -sfS -X DELETE "${API}/releases/assets/${OLD_ASSET_ID}" "${AUTH[@]}" >/dev/null 2>&1 || true
      info "已移除旧附件（id=${OLD_ASSET_ID}）"
    fi

    UPLOAD_URL="https://uploads.github.com/repos/${REPO_SLUG}/releases/${RELEASE_ID}/assets?name=${DMG_NAME}"
    info "上传 ${DMG_NAME}（$(du -h "${DMG_PATH}" | cut -f1)）…"
    # --data-binary 而非 -d：保证二进制不被当文本处理
    curl -sfS -X POST "${UPLOAD_URL}" "${AUTH[@]}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${DMG_PATH}" >/dev/null || error "上传附件失败"
    info "附件上传完成"
  fi
fi

# ── 完成 ────────────────────────────────────────────────────
echo ""
if [ "${DRY_RUN}" = true ]; then
  echo -e "${YELLOW}（dry-run，未改动远端）${NC}"
else
  echo -e "${GREEN}✅ 发布完成${NC}"
  echo "   tag     ${TAG}"
  echo "   附件    ${DMG_NAME}（$(du -h "${DMG_PATH}" | cut -f1)）"
  echo "   页面    https://github.com/${REPO_SLUG}/releases/tag/${TAG}"
  if [ "${DRAFT}" = true ]; then
    echo -e "   ${YELLOW}注意：当前是草稿，需到网页点 Publish release 才公开${NC}"
  fi
  if [ "${DIRTY}" = "1" ]; then
    echo -e "   ${YELLOW}提醒：工作区仍有未提交改动，它们不在本次 tag 里${NC}"
  fi
fi
echo ""
