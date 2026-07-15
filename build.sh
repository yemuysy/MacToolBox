#!/bin/bash
#
# MacToolBox 构建脚本
# 不依赖 Xcode，使用 swiftc + Command Line Tools 直接编译
# 输出 build/MacToolBox.app

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

APP_NAME="MacToolBox"
SOURCE_DIR="Sources/MacToolBox"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME"
echo "    Project dir: $PROJECT_DIR"

# 1. 清理旧构建
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 2. 收集所有 Swift 源文件
SWIFT_FILES=$(find "$SOURCE_DIR" -name "*.swift" | sort)
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

# 5. 编译
echo "==> Compiling..."
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
    -framework IOKit \
    -framework OSLog \
    -framework Carbon \
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
# 主图标 (.icns) 和菜单栏模板图标 (png) 来自 Resources/ 目录
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

# 8. 完成
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
