#!/usr/bin/env bash
# 把核心塞进 Flutter .app,用 create-dmg 打 dmg。
# 用法: package.sh <app路径> <核心路径> <输出dmg> <卷名>
set -euo pipefail
APP="$1"
CORE="$2"
DMG="$3"
VOL="$4"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# 核心放进 .app/Contents/MacOS,与 eglan_ui 同目录(IpcBridge.probe 能找到)
cp "$CORE" "$APP/Contents/MacOS/egland"
chmod +x "$APP/Contents/MacOS/egland"
cp "$ROOT/LICENSE" "$APP/Contents/MacOS/LICENSE.txt"
[ -f "$ROOT/THIRD_PARTY_LICENSES.md" ] && cp "$ROOT/THIRD_PARTY_LICENSES.md" "$APP/Contents/MacOS/THIRD_PARTY_LICENSES.txt"

# 修正 executable 的 rpath 不需要;核心是独立二进制。
hdiutil create -volname "$VOL" -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "DMG=$DMG"
