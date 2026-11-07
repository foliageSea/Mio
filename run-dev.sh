#!/bin/zsh
# 使用 Debug 配置构建并在当前终端运行 Mio。
set -euo pipefail

usage() {
  print "用法: ./run-dev.sh [--build-only | --help]"
  print "  默认: 增量构建 Debug 版本并运行，日志输出到当前终端，Ctrl+C 结束。"
  print "  --build-only: 仅构建和签名，不启动应用。"
}

BUILD_ONLY=0
if (( $# > 1 )); then
  usage >&2
  exit 2
fi
case "${1:-}" in
  "") ;;
  --build-only) BUILD_ONLY=1 ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="$PROJECT_DIR/build/DevDerivedData"
BUILD_LOG="$PROJECT_DIR/build/dev-build.log"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Mio.app"

command -v xcodebuild >/dev/null || { print -u2 "未找到 xcodebuild，请先安装并选择 Xcode。"; exit 1; }
mkdir -p "$PROJECT_DIR/build"
print "构建 Mio (Debug)..."
if ! xcodebuild \
  -project "$PROJECT_DIR/Mio.xcodeproj" \
  -scheme Mio \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build >"$BUILD_LOG" 2>&1; then
  tail -n 60 "$BUILD_LOG" >&2
  print -u2 "构建失败，完整日志: $BUILD_LOG"
  exit 1
fi

# 本机开发使用 ad-hoc 签名，无需配置开发团队。
codesign --force --sign - "$APP_PATH"
codesign --verify --strict "$APP_PATH"
print "构建完成: $APP_PATH"

if (( BUILD_ONLY )); then
  exit 0
fi

print "启动 Mio，日志输出到当前终端；按 Ctrl+C 结束。"
exec "$APP_PATH/Contents/MacOS/Mio"
