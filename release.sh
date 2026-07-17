#!/bin/bash
#
# MacToolBox 一键发布脚本（基于 gh CLI）
#
# 功能：
#   1. 自动用钥匙串里保存的 GitHub token 登录 gh（无需手动 auth）
#   2. 构建并打包出 dist/MacToolBox-<version>.dmg（可用 --no-build 跳过构建）
#   3. 打 git tag 并推送到 origin
#   4. 用 gh 创建 GitHub Release 并上传 DMG（已存在则补传 asset，幂等）
#
# 用法：
#   ./release.sh                 # 用 Info.plist 里的版本号发布
#   ./release.sh 1.0.1           # 指定版本号发布
#   ./release.sh --no-build      # 跳过 ./build.sh，仅用已有 build/ 重新打包
#
# 依赖：gh（brew install gh）、build.sh、package.sh、钥匙串里 github.com 的 token

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------
VERSION=""
NO_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=1 ;;
        -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
        *) VERSION="$arg" ;;
    esac
done

# 版本号默认取自 Info.plist
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo '1.0.0')"
fi
TAG="v${VERSION}"
DMG_FILE="dist/MacToolBox-${VERSION}.dmg"

echo "==> MacToolBox 发布流程 (version=$VERSION, tag=$TAG)"

# ---------------------------------------------------------------------------
# 0. gh 登录（优先钥匙串 token，免交互）
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: 未找到 gh，请先执行  brew install gh" >&2
    exit 1
fi

# 优先用钥匙串里保存的 token 注入 GITHUB_TOKEN（绕开 gh auth login 的 scope 校验，
# 发版只需 repo scope，钥匙串 token 已具备；read:org 缺失不影响 release 操作）
TOKEN="$(security find-internet-password -s github.com -w 2>/dev/null || true)"
if [ -n "$TOKEN" ]; then
    export GITHUB_TOKEN="$TOKEN"
    echo "==> 使用钥匙串 token（GITHUB_TOKEN）"
else
    # 无钥匙串 token 时，回退到已手动 gh auth login 的登录态
    if ! gh auth status >/dev/null 2>&1; then
        echo "ERROR: 钥匙串无 github.com 的 token 且 gh 未登录，请先 gh auth login" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 1. 构建 + 打包
# ---------------------------------------------------------------------------
if [ "$NO_BUILD" -eq 0 ]; then
    echo "==> 构建 App"
    ./build.sh
fi
echo "==> 打包 DMG"
./package.sh

if [ ! -f "$DMG_FILE" ]; then
    echo "ERROR: 打包未产出 $DMG_FILE" >&2
    exit 1
fi
echo "    DMG: $DMG_FILE ($(du -h "$DMG_FILE" | awk '{print $1}'))"

# ---------------------------------------------------------------------------
# 2. git tag（已存在则跳过）
# ---------------------------------------------------------------------------
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "==> tag $TAG 已存在，跳过创建"
else
    echo "==> 创建 tag $TAG"
    PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "$PREV_TAG" ]; then
        NOTES="$(git log --pretty=format:'- %s' "${PREV_TAG}..HEAD")"
    else
        NOTES="$(git log --pretty=format:'- %s' -n 30)"
    fi
    [ -z "$NOTES" ] && NOTES="- 版本 $VERSION 发布"
    git tag -a "$TAG" -m "MacToolBox $VERSION

$NOTES"
    echo "==> 推送 tag $TAG"
    git push origin "$TAG"
fi

# ---------------------------------------------------------------------------
# 3. 创建 / 更新 GitHub Release（gh）
# ---------------------------------------------------------------------------
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "==> Release $TAG 已存在，补传/更新 asset"
    gh release upload "$TAG" "$DMG_FILE" --clobber
else
    echo "==> 创建 Release $TAG 并上传 DMG"
    PREV_TAG="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
    if [ -n "$PREV_TAG" ]; then
        NOTES="$(git log --pretty=format:'- %s' "${PREV_TAG}..${TAG}")"
    else
        NOTES="$(git log --pretty=format:'- %s' -n 30)"
    fi
    [ -z "$NOTES" ] && NOTES="- 版本 $VERSION 发布"
    gh release create "$TAG" "$DMG_FILE" \
        --title "MacToolBox $VERSION" \
        --notes "$NOTES" \
        --target main
fi

echo ""
echo "==> 发布完成 ✅"
echo "    https://github.com/yemuysy/MacToolBox/releases/tag/$TAG"
