#!/bin/bash
#
# MacToolBox 打包脚本
# 依赖 ./build.sh 先产出 build/MacToolBox.app
# 输出 dist/MacToolBox-<version>.dmg（含拖拽安装布局 + 安装说明）
#
# 说明：本版本为 ad-hoc 签名（无 Developer ID 证书），DMG 内 app 首次打开
#       会被 Gatekeeper 拦截，需在安装说明.txt 中提示右键打开 / xattr 解除隔离。

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

APP_BUNDLE="build/MacToolBox.app"
if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: $APP_BUNDLE not found. Run ./build.sh first." >&2
    exit 1
fi

# 版本号（取自 Info.plist）
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo '1.0.0')"
DMG_NAME="MacToolBox-${VERSION}"
DMG_FILE="dist/${DMG_NAME}.dmg"
STAGING="dist/.dmg_staging"

echo "==> Packaging $DMG_NAME (from $(du -sh "$APP_BUNDLE" | awk '{print $1}'))"

# 清理并准备暂存目录
rm -rf "dist"
mkdir -p "$STAGING"

# 拷贝 app（保留签名/资源分支）
cp -R "$APP_BUNDLE" "$STAGING/MacToolBox.app"
# Applications 软链，便于拖拽安装
ln -s /Applications "$STAGING/Applications"

# 安装说明（中文，覆盖 ad-hoc 签名的 Gatekeeper 限制 + Finder Sync 扩展限制）
cat > "$STAGING/安装说明.txt" <<'EOF'
MacToolBox 安装说明
==================

1. 将 MacToolBox.app 拖入「Applications」文件夹。

2. 首次打开：本版本为 ad-hoc 签名（没有 Apple Developer ID 证书），
   macOS Gatekeeper 可能会拦截。请二选一：
     · 右键点击 App →「打开」，在弹窗中点「仍要打开」；
     · 或终端执行：sudo xattr -rd com.apple.quarantine /Applications/MacToolBox.app

3. 右键增强：Finder 一级菜单依赖已签名的 Finder Sync 扩展（本版本未签名，
   系统不会注册扩展）。请用 Finder 右键「服务」子菜单里的「MacToolBox：xxx」
   免费路线（复制路径 / 新建文件 / 在终端打开 / 在 Finder 中显示 / 从模板新建 等）。

若要启用 Finder Sync 一级菜单，需用 Developer ID Application 证书 + Hardened
Runtime 重新签名（见 build.sh 顶部 SIGN_IDENTITY / TEAM_ID 说明）。

更多信息见项目 README。
EOF

# 创建 DMG（UDZO 压缩）
echo "==> Creating DMG: $DMG_FILE"
hdiutil create -volname "$DMG_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_FILE"

# 尽力美化窗口（无 GUI 环境下失败不致命）
set +e
DMG_MOUNT="$(hdiutil attach "$DMG_FILE" -nobrowse -noautoopen 2>/dev/null | tail -1 | awk '{print $NF}')"
if [ -n "$DMG_MOUNT" ]; then
    osascript <<EOF 2>/dev/null || true
tell application "Finder"
    tell disk "$DMG_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 920, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set position of item "MacToolBox.app" of container window to {160, 180}
        set position of item "Applications" of container window to {380, 180}
        set position of item "安装说明.txt" of container window to {270, 330}
        close
    end tell
end tell
EOF
    hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null || true
fi
set -e

echo ""
echo "==> Package SUCCESS"
echo "    DMG:  $DMG_FILE"
echo "    Size: $(du -sh "$DMG_FILE" | awk '{print $1}')"
ls -la "$DMG_FILE"
