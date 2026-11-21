#!/usr/bin/env bash
# 合成 Linux payload,再打 AppImage / deb / rpm。
# 用法: package.sh <Flutter bundle 目录> <x64|arm64> <核心可执行文件> <输出目录> [版本]
set -euo pipefail

BUNDLE="$(cd "$1" && pwd)"
ARCH="$2"
CORE="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
OUT="$(mkdir -p "$4" && cd "$4" && pwd)"
VERSION="${5:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_NAME="evergreen-lan"

case "$ARCH" in
  x64)   APPIMAGE_ARCH="x86_64"; DEB_ARCH="amd64";  RPM_ARCH="x86_64";  TOOL_ARCH="x86_64" ;;
  arm64) APPIMAGE_ARCH="aarch64"; DEB_ARCH="arm64"; RPM_ARCH="aarch64"; TOOL_ARCH="aarch64" ;;
  *) echo "未知架构: $ARCH" >&2; exit 1 ;;
esac

PAYLOAD="$OUT/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
cp -a "$BUNDLE"/. "$PAYLOAD"/
cp "$CORE" "$PAYLOAD/egland"
chmod +x "$PAYLOAD/egland"
cp "$ROOT/LICENSE" "$PAYLOAD/LICENSE.txt"
if [ -f "$ROOT/THIRD_PARTY_LICENSES.md" ]; then
  cp "$ROOT/THIRD_PARTY_LICENSES.md" "$PAYLOAD/THIRD_PARTY_LICENSES.txt"
fi

echo "=== AppImage ==="
APPDIR="$OUT/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$PAYLOAD"/. "$APPDIR/usr/bin"/
cp "$ROOT/packaging/linux/eglan.desktop" "$APPDIR/eglan.desktop"
cp "$ROOT/packaging/linux/eglan.desktop" "$APPDIR/usr/share/applications/eglan.desktop"
cp "$ROOT/packaging/linux/eglan.png" "$APPDIR/eglan.png"
cp "$ROOT/packaging/linux/eglan.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/eglan.png"
ln -sf eglan.png "$APPDIR/.DirIcon"

cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/eglan_ui" "$@"
EOF
chmod +x "$APPDIR/AppRun"

TOOL="$OUT/appimagetool"
if [ ! -x "$TOOL" ]; then
  curl -fsSL --retry 3 \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${TOOL_ARCH}.AppImage" \
    -o "$TOOL"
  chmod +x "$TOOL"
fi
(
  cd "$OUT"
  ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 \
    "$TOOL" AppDir "$APP_NAME-linux-$ARCH.AppImage"
)
echo "APPIMAGE=$OUT/$APP_NAME-linux-$ARCH.AppImage"

echo "=== deb ==="
DEB_ROOT="$OUT/debroot"
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT/opt/eglan" "$DEB_ROOT/usr/bin" \
         "$DEB_ROOT/usr/share/applications" \
         "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps"
cp -a "$PAYLOAD"/. "$DEB_ROOT/opt/eglan"/
cat > "$DEB_ROOT/usr/bin/eglan_ui" <<'EOF'
#!/bin/sh
exec /opt/eglan/eglan_ui "$@"
EOF
chmod +x "$DEB_ROOT/usr/bin/eglan_ui"
cp "$ROOT/packaging/linux/eglan.desktop" "$DEB_ROOT/usr/share/applications/eglan.desktop"
cp "$ROOT/packaging/linux/eglan.png" "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/eglan.png"

SIZE_KB="$(du -sk "$DEB_ROOT/opt" | cut -f1)"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Section: games
Priority: optional
Architecture: $DEB_ARCH
Maintainer: EverGreen LAN <dev@eglan.local>
Installed-Size: $SIZE_KB
Depends: libgtk-3-0 | libgtk-3-0t64, libblkid1, liblzma5
Description: End-to-end encrypted LAN gaming tool
 EverGreen LAN creates a virtual network adapter so games see each
 other on a real LAN, with no central server.
EOF
dpkg-deb --root-owner-group --build "$DEB_ROOT" "$OUT/$APP_NAME-linux-$ARCH.deb" >/dev/null
echo "DEB=$OUT/$APP_NAME-linux-$ARCH.deb"

echo "=== rpm ==="
if ! command -v fpm >/dev/null 2>&1; then
  echo "缺少 fpm,无法生成 rpm" >&2
  exit 1
fi
fpm -s dir -t rpm \
    -C "$DEB_ROOT" \
    --architecture "$RPM_ARCH" \
    --name "$APP_NAME" \
    --version "$VERSION" \
    --license "Apache-2.0" \
    --vendor "EverGreen LAN" \
    --maintainer "EverGreen LAN <dev@eglan.local>" \
    --url "https://github.com/aliu-Bruce/EverGreen-LAN" \
    --description "End-to-end encrypted LAN gaming tool" \
    --depends gtk3 \
    --depends libblkid \
    --depends xz-libs \
    --package "$OUT/$APP_NAME-linux-$ARCH.rpm" \
    opt usr >/dev/null
echo "RPM=$OUT/$APP_NAME-linux-$ARCH.rpm"
