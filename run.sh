#!/bin/bash
#
# MacToolBox 启动脚本
# 用法: ./run.sh [build|open|rebuild|clean]

set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$PROJECT_DIR/build/MacToolBox.app"

case "${1:-open}" in
    build)
        "$PROJECT_DIR/build.sh"
        ;;
    open)
        if [ ! -d "$APP" ]; then
            echo "App 还未构建, 先执行 build..."
            "$PROJECT_DIR/build.sh"
        fi
        # 如果已运行则先关闭
        pkill -f "MacToolBox.app/Contents/MacOS/MacToolBox" 2>/dev/null || true
        sleep 0.5
        open "$APP"
        echo "MacToolBox 已在菜单栏启动 (🛠 MTB)"
        echo "点击菜单栏图标打开面板"
        ;;
    rebuild)
        pkill -f "MacToolBox.app/Contents/MacOS/MacToolBox" 2>/dev/null || true
        sleep 0.5
        rm -rf "$PROJECT_DIR/build"
        "$PROJECT_DIR/build.sh"
        open "$APP"
        ;;
    stop)
        pkill -f "MacToolBox.app/Contents/MacOS/MacToolBox" 2>/dev/null || true
        echo "已关闭 MacToolBox"
        ;;
    clean)
        pkill -f "MacToolBox.app/Contents/MacOS/MacToolBox" 2>/dev/null || true
        rm -rf "$PROJECT_DIR/build"
        echo "已清理 build 目录"
        ;;
    status)
        ps aux | grep -i "MacToolBox.app/Contents/MacOS" | grep -v grep || echo "未运行"
        ;;
    *)
        echo "用法: $0 {open|build|rebuild|stop|clean|status}"
        exit 1
        ;;
esac
