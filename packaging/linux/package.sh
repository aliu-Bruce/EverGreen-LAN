#!/usr/bin/env bash
# 合成 Linux payload,再打 AppImage / deb / rpm。
set -euo pipefail
BUNDLE="$1"      # Flutter bundle 目录(build/linux/<arch>/release/bundle)
ARCH="$2"        # x64 / arm64
CORE="$3"        # 核心可执行文件路径
OUT="$4"         # 输出目录
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$OUT"
PAYLOAD="$OUT/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
cp -a "$BUNDLE"/. "$PAYLOAD"/
cp "$CORE" "$PAYLOAD/egland"
cp "$ROOT/LICENSE" "$PAYLOAD/LICENSE.txt"
[ -f "$ROOT/THIRD_PARTY_LICENSES.md" ] && cp "$ROOT/THIRD_PARTY_LICENSES.md" "$PAYLOAD/THIRD_PARTY_LICENSES.txt"

# --- AppImage ---
APPDIR="$OUT/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$PAYLOAD"/. "$APPDIR/usr/bin"/
cp "$ROOT/packaging/linux/eglan.desktop" "$APPDIR/usr/share/applications/eglan.desktop"
cp "$ROOT/assets/icon/icon.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/eglan.png"
cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/eglan_ui" "$@"
EOF
chmod +x "$APPDIR/AppRun"

TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
if [ "$ARCH" = "arm64" ]; then
  TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-aarch64.AppImage"
fi
curl -fsSL "$TOOL_URL" -o "$OUT/appimagetool"
chmod +x "$OUT/appimagetool"
(
  cd "$OUT"
  ARCH=x86_64 ./appimagetool AppDir "EverGreen-LAN-linux-$ARCH.AppImage" || \
  ./appimagetool AppDir "EverGreen-LAN-linux-$ARCH.AppImage"
)
echo "APPIMAGE=$OUT/EverGreen-LAN-linux-$ARCH.AppImage"

# --- deb (dpkg-deb) ---
DEB_ROOT="$OUT/debroot"
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT/opt/eglan" "$DEB_ROOT/usr/share/applications"
cp -a "$PAYLOAD"/. "$DEB_ROOT/opt/eglan"/
cp "$ROOT/packaging/linux/eglan.desktop" "$DEB_ROOT/usr/share/applications/eglan.desktop"
DEB_ARCH="amd64"; [ "$ARCH" = "arm64" ] && DEB_ARCH="arm64"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: evergreen-lan
Version: 0.1.0
Section: games
Priority: optional
Architecture: $DEB_ARCH
Maintainer: EverGreen LAN <dev@eglan.local>
Description: End-to-end encrypted LAN gaming tool
 Creates a virtual network adapter so games see each other on a real LAN.
EOF
dpkg-deb --build "$DEB_ROOT" "$OUT/evergreen-lan-linux-$ARCH.deb"
echo "DEB=$OUT/evergreen-lan-linux-$ARCH.deb"

# --- rpm (fpm,从 deb 转) ---
if command -v fpm >/dev/null 2>&1; then
  RPM_ARCH="x86_64"; [ "$ARCH" = "arm64" ] && RPM_ARCH="aarch64"
  fpm -s deb -t rpm --architecture "$RPM_ARCH" \
      -n evergreen-lan -v 0.1.0 \
      -p "$OUT/evergreen-lan-linux-$ARCH.rpm" \
      "$OUT/evergreen-lan-linux-$ARCH.deb"
  echo "RPM=$OUT/evergreen-lan-linux-$ARCH.rpm"
else
  echo "SKIP_RPM=fpm not installed"
fi
