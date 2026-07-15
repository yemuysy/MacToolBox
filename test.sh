#!/bin/bash
#
# MacToolBox 沙盒测试
# 编译 Sources(排除 @main 入口) + Tests 为独立二进制并运行。
# 每个功能模块都有对应的纯逻辑/沙盒测试，无需真实 UI 或特权。

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

APP_NAME="MacToolBox"
SRC_DIR="Sources/MacToolBox"
TEST_DIR="Tests"
BUILD_DIR="build/test"

SDK_PATH=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
MIN_MACOS="13.0"
ARCH=$(uname -m)

mkdir -p "$BUILD_DIR"

# 复用模块缓存，加速重复编译（测试默认 debug 优化 -Onone，远快于 -O 且不影响结果）
MODULE_CACHE="$BUILD_DIR/module-cache"
mkdir -p "$MODULE_CACHE"

# 收集源文件：排除含 @main 的应用入口（避免与测试顶层入口冲突）
SWIFT_FILES=$(find "$SRC_DIR" -name '*.swift' ! -name 'MacToolBoxApp.swift' | sort)
SWIFT_FILES="$SWIFT_FILES $(find "$TEST_DIR" -name '*.swift' | sort)"

echo "==> Test sources:"
echo "$SWIFT_FILES" | sed 's/^/    /'

echo "==> Compiling test runner..."
swiftc \
    -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -module-name TestRunner \
    -parse-as-library \
    -swift-version 6 \
    -Onone \
    -module-cache-path "$MODULE_CACHE" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework DiskArbitration \
    -framework CoreFoundation \
    -framework IOKit \
    -framework OSLog \
    -framework Carbon \
    -o "$BUILD_DIR/test_runner" \
    $SWIFT_FILES

echo "==> Running tests..."
"$BUILD_DIR/test_runner"
