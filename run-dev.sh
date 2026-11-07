#!/bin/zsh
# 使用 Debug 配置构建并在当前终端运行 Mio。
set -euo pipefail

usage() {
  print "用法: ./run-dev.sh [--build-only | --help]"
  print "  默认: 增量构建并运行；r 重新构建并重启，q 或 Ctrl+C 退出。"
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
APP_PID=""

stop_app() {
  if [[ -n "$APP_PID" ]]; then
    if kill -0 "$APP_PID" 2>/dev/null; then
      kill -TERM "$APP_PID" 2>/dev/null || true
    fi
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
  fi
}

trap stop_app EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

build_app() {
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
    return 1
  fi

  # 本机开发使用 ad-hoc 签名，无需配置开发团队。
  if ! codesign --force --sign - "$APP_PATH" || ! codesign --verify --strict "$APP_PATH"; then
    print -u2 "应用签名失败。"
    return 1
  fi
  print "构建完成: $APP_PATH"
}

start_app() {
  print "启动 Mio，日志输出到当前终端。"
  "$APP_PATH/Contents/MacOS/Mio" </dev/null &
  APP_PID=$!
}

command -v xcodebuild >/dev/null || { print -u2 "未找到 xcodebuild，请先安装并选择 Xcode。"; exit 1; }
mkdir -p "$PROJECT_DIR/build"
build_app || exit 1
if (( BUILD_ONLY )); then
  exit 0
fi

start_app
if [[ ! -t 0 ]]; then
  # 非交互调用保留等待应用退出的行为，不读取终端按键。
  APP_EXIT_CODE=0
  wait "$APP_PID" || APP_EXIT_CODE=$?
  APP_PID=""
  exit "$APP_EXIT_CODE"
fi

print "按 r 重新构建并重启，按 q 或 Ctrl+C 退出。"
while true; do
  if [[ -n "$APP_PID" ]] && ! kill -0 "$APP_PID" 2>/dev/null; then
    APP_EXIT_CODE=0
    wait "$APP_PID" || APP_EXIT_CODE=$?
    APP_PID=""
    print "Mio 已退出（$APP_EXIT_CODE）；按 r 重启，按 q 退出开发模式。"
  fi
  key=""
  if read -rs -k 1 -t 0.2 key; then
    case "$key" in
      r|R)
        stop_app
        if build_app; then
          start_app
        else
          print -u2 "按 r 重试构建，按 q 退出。"
        fi
        ;;
      q|Q) exit 0 ;;
    esac
  fi
done
