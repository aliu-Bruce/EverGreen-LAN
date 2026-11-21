#!/usr/bin/env bash
# 把核心塞进 Flutter .app,重签为 ad-hoc 签名,再打 dmg。
# 用法: package.sh <app 路径> <核心路径> <输出 dmg> <卷名> [输出目录]
set -euo pipefail

APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
CORE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
DMG="$3"
VOL="$4"
OUT_DIR="$(dirname "$DMG")"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT_DIR"

# 核心与许可放进 .app/Contents/MacOS,与 UI 可执行文件同目录
cp "$CORE" "$APP/Contents/MacOS/egland"
chmod +x "$APP/Contents/MacOS/egland"
cp "$ROOT/LICENSE" "$APP/Contents/MacOS/LICENSE.txt"
if [ -f "$ROOT/THIRD_PARTY_LICENSES.md" ]; then
  cp "$ROOT/THIRD_PARTY_LICENSES.md" "$APP/Contents/MacOS/THIRD_PARTY_LICENSES.txt"
fi

# 新增文件会破坏原签名,统一重签为 ad-hoc(无需开发者证书)
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# 卷内附 Applications 快捷方式,方便拖拽安装
STAGE="$(cd "$OUT_DIR" && pwd)/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "DMG=$DMG"
