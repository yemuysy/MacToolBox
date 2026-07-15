#!/bin/bash
#
# MacToolBox 构建脚本
# 不依赖 Xcode，使用 swiftc + Command Line Tools 直接编译
# 输出 build/MacToolBox.app（含内嵌的 FinderSyncExt.appex 扩展）

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

APP_NAME="MacToolBox"
SOURCE_DIR="Sources/MacToolBox"
SHARED_DIR="Sources/Shared"
EXT_DIR="Sources/FinderSyncExt"
EXT_NAME="FinderSyncExt"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME"
echo "    Project dir: $PROJECT_DIR"

# 1. 清理旧构建（仅清本脚本产物：.app bundle 与主二进制，保留 build/test 模块缓存以加速测试）
rm -rf "$APP_BUNDLE"
rm -f "$BUILD_DIR/$APP_NAME"
mkdir -p "$BUILD_DIR"

# 2. 收集所有 Swift 源文件（主程序 + 共享 IPC 层；扩展单独编译，不并入主程序）
SWIFT_FILES=$(find "$SOURCE_DIR" "$SHARED_DIR" -name "*.swift" | sort)
FILE_COUNT=$(echo "$SWIFT_FILES" | wc -l | tr -d ' ')
echo "==> Found $FILE_COUNT source files"
echo "$SWIFT_FILES" | sed 's/^/    /'

# 3. 探测 SDK
SDK_PATH=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
echo "==> Using SDK: $SDK_PATH"

# 4. 探测最小目标系统（默认 13.0，Ventura 起 MenuBarExtra 可用）
MIN_MACOS="13.0"
ARCH=$(uname -m)
echo "==> Target: $ARCH-apple-macos$MIN_MACOS"

# 5. 编译主程序
echo "==> Compiling main app..."
swiftc \
    -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -parse-as-library \
    -module-name "$APP_NAME" \
    -swift-version 6 \
    -O \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework DiskArbitration \
    -framework CoreFoundation \
    -framework CoreGraphics \
    -framework ApplicationServices \
    -framework IOKit \
    -framework OSLog \
    -framework Carbon \
    -framework CryptoKit \
    -o "$BUILD_DIR/$APP_NAME" \
    $SWIFT_FILES

echo "==> Compile OK"

# 6. 构建 .app bundle
echo "==> Assembling .app bundle"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# PkgInfo（8 字节，标识 APPL 应用）
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# 7. 复制图标资源
ICON_DIR="Resources"
if [ -f "$ICON_DIR/AppIcon.icns" ]; then
    cp "$ICON_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "    AppIcon.icns copied"
else
    echo "    Warning: AppIcon.icns not found"
fi
if [ -f "$ICON_DIR/MenuBarIcon.png" ]; then
    cp "$ICON_DIR/MenuBarIcon.png" "$APP_BUNDLE/Contents/Resources/MenuBarIcon.png"
    echo "    MenuBarIcon.png copied"
else
    echo "    Warning: MenuBarIcon.png not found"
fi

# 8. 编译并内嵌 Finder Sync 扩展
#    关键：app 扩展的可执行文件必须是 MH_EXECUTE 且入口为 NSExtensionMain，
#    绝不能用 -bundle（那会产出 MH_BUNDLE，pluginkit 拒绝注册，Finder 永远看不到菜单）。
#    正确做法：以 -parse-as-library 编译（无 @main），用链接器 -e 指定入口 _NSExtensionMain（由 Foundation 提供）。
echo "==> Compiling Finder Sync extension..."
EXT_FILES=$(find "$EXT_DIR" "$SHARED_DIR" -name "*.swift" | sort)
EXT_BIN="$BUILD_DIR/$EXT_NAME"
swiftc \
    -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -parse-as-library \
    -module-name "$EXT_NAME" \
    -swift-version 6 \
    -O \
    -framework Foundation \
    -framework AppKit \
    -framework FinderSync \
    -framework CryptoKit \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$EXT_BIN" \
    $EXT_FILES

APPEX="$APP_BUNDLE/Contents/PlugIns/$EXT_NAME.appex"
mkdir -p "$APPEX/Contents/MacOS"
mkdir -p "$APPEX/Contents/Resources"
cp "$EXT_BIN" "$APPEX/Contents/MacOS/$EXT_NAME"
cp "$EXT_DIR/Info.plist" "$APPEX/Contents/Info.plist"
echo "    $EXT_NAME.appex assembled"

# 9. 代码签名（开发期 ad-hoc；分发需 Developer ID）
#    先签扩展，再签主程序（主程序签名会校验内嵌 appex 的签名）
echo "==> Code signing..."
codesign --force --sign - "$APPEX"
codesign --force --sign - "$APP_BUNDLE"
echo "    signed appex + app"

# 10. 完成
APP_SIZE=$(du -sh "$APP_BUNDLE" | awk '{print $1}')
echo ""
echo "==> Build SUCCESS"
echo "    Bundle: $APP_BUNDLE"
echo "    Size:   $APP_SIZE"
echo ""
echo "Run with:"
echo "    open $APP_BUNDLE"
echo ""
echo "View logs with:"
echo "    log stream --predicate 'subsystem == \"com.yemu.mactoolbox\"' --style compact"
