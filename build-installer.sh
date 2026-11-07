#!/bin/zsh
# Mio 一键构建 + 打包脚本
#
# 产物(输出到 dist/):
#   Mio-<version>.dmg  拖拽安装镜像(含 /Applications 快捷方式)
#   Mio-<version>.pkg  标准 macOS 安装器(安装到 /Applications)
#
# 环境变量(均可选):
#   VERSION            覆盖版本号(默认读取构建产物的 CFBundleShortVersionString)
#   CODESIGN_IDENTITY  应用签名身份,如 "Developer ID Application: Your Name (TEAMID)"
#                      缺省时使用本机 ad-hoc 签名(仅适合本机运行)
#   PKG_IDENTITY       安装包签名身份,如 "Developer ID Installer: Your Name (TEAMID)"
#                      缺省时 PKG 不签名
#   NOTARY_PROFILE     notarytool 的 keychain profile 名称,设置后自动公证并 stapler
#   SKIP_BUILD=1       跳过编译,直接使用 build/ 下已有的 Mio.app
#   BUILD_NUMBER       覆盖 CFBundleVersion(默认 1)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/Mio.xcodeproj"
SCHEME="Mio"
CONFIG="Release"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$BUILD_DIR/Mio.app"
BUNDLE_ID="com.foliage.Mio"
DERIVED_DATA=""

cleanup() {
  if [[ -n "$DERIVED_DATA" && -d "$DERIVED_DATA" ]]; then
    rm -rf "$DERIVED_DATA"
  fi
}
trap cleanup EXIT INT TERM

log()  { print -P "%F{cyan}▸%f $*"; }
ok()   { print -P "%F{green}✔%f $*"; }
die()  { print -P "%F{red}✘ $*%f" >&2; exit 1; }

command -v xcodebuild >/dev/null || die "未找到 xcodebuild,请先安装 Xcode"
command -v hdiutil    >/dev/null || die "未找到 hdiutil"
command -v pkgbuild   >/dev/null || die "未找到 pkgbuild"

# ---------- 1. 编译 ----------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "编译 $SCHEME ($CONFIG, universal arm64+x86_64)"
  mkdir -p "$BUILD_DIR"
  rm -rf "$BUILD_DIR/Mio.app" "$BUILD_DIR/Mio.app.dSYM"
  DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/Mio-DerivedData.XXXXXX")"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build >"$BUILD_DIR/xcodebuild.log" 2>&1 \
    || { tail -40 "$BUILD_DIR/xcodebuild.log"; die "编译失败,完整日志: $BUILD_DIR/xcodebuild.log"; }
  cp -R "$DERIVED_DATA/Build/Products/$CONFIG/Mio.app" "$APP_PATH"
  [[ -d "$DERIVED_DATA/Build/Products/$CONFIG/Mio.app.dSYM" ]] && \
    cp -R "$DERIVED_DATA/Build/Products/$CONFIG/Mio.app.dSYM" "$BUILD_DIR/"
  ok "编译完成"
fi
[[ -d "$APP_PATH" ]] || die "未找到 $APP_PATH"

# ---------- 2. 签名 ----------
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  log "使用身份签名: $CODESIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$CODESIGN_IDENTITY" "$APP_PATH"
else
  log "未设置 CODESIGN_IDENTITY,使用本机 ad-hoc 签名"
  codesign --force --deep --sign - "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH" && ok "签名校验通过"

# ---------- 3. 版本号 ----------
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")}"
[[ -n "$VERSION" ]] || die "无法确定版本号"
PKG_NAME="Mio-$VERSION"
ok "版本: $VERSION"

# ---------- 4. DMG ----------
log "生成 DMG 安装镜像"
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$PKG_NAME.dmg"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "Mio $VERSION" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGING"
ok "DMG: $DMG_PATH"

# ---------- 5. PKG ----------
log "生成 PKG 安装器"
PKG_ROOT="$BUILD_DIR/pkg-root"
COMPONENT_PKG="$BUILD_DIR/Mio-component.pkg"
PKG_PATH="$DIST_DIR/$PKG_NAME.pkg"
rm -rf "$PKG_ROOT" "$COMPONENT_PKG" "$PKG_PATH"
mkdir -p "$PKG_ROOT"
cp -R "$APP_PATH" "$PKG_ROOT/"

pkgbuild \
  --root "$PKG_ROOT" \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --install-location "/Applications" \
  ${PKG_IDENTITY:+--sign "$PKG_IDENTITY"} \
  "$COMPONENT_PKG" >/dev/null

# 生成带欢迎/许可信息的分发式安装包
DIST_XML="$BUILD_DIR/distribution.xml"
cat > "$DIST_XML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Mio $VERSION</title>
    <organization>$BUNDLE_ID</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <choices-outline>
        <line choice="default">
            <line choice="$BUNDLE_ID"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$BUNDLE_ID" visible="false">
        <pkg-ref id="$BUNDLE_ID"/>
    </choice>
    <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">Mio-component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild \
  --distribution "$DIST_XML" \
  --package-path "$BUILD_DIR" \
  ${PKG_IDENTITY:+--sign "$PKG_IDENTITY"} \
  "$PKG_PATH"
rm -rf "$PKG_ROOT" "$COMPONENT_PKG" "$DIST_XML"
ok "PKG: $PKG_PATH"

# ---------- 6. 公证(可选) ----------
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    log "警告: ad-hoc 签名的应用无法通过公证,跳过"
  else
    log "提交公证(keychain profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun notarytool submit "$PKG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG_PATH"
    ok "公证完成"
  fi
fi

print ""
ok "全部完成,产物位于 dist/:"
ls -lh "$DIST_DIR" | tail -n +2
