#!/bin/bash
# Build FableUsage.app into ~/Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/FableUsage.app"

mkdir -p build

# This machine's Command Line Tools ship a stale usr/include/swift/module.modulemap (2023) next to
# bridging.modulemap, which breaks `import Cocoa` with "redefinition of module 'SwiftBridging'".
# Hide it with a VFS overlay instead of touching the root-owned file.
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
OVERLAY_FLAGS=()
if [[ -f "$STALE" && -f "$(dirname "$STALE")/bridging.modulemap" ]]; then
  : > build/empty.modulemap
  cat > build/vfs-overlay.yaml <<EOF
{"version": 0, "roots": [{"type": "file", "name": "$STALE", "external-contents": "$PWD/build/empty.modulemap"}]}
EOF
  OVERLAY_FLAGS=(-vfsoverlay build/vfs-overlay.yaml -Xcc -ivfsoverlay -Xcc build/vfs-overlay.yaml)
fi

swiftc -O -swift-version 5 "${OVERLAY_FLAGS[@]}" -o build/FableUsage main.swift

pkill -x FableUsage 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp build/FableUsage "$APP/Contents/MacOS/FableUsage"
codesign --force --sign - "$APP"

# Reinstalling replaces the bundle and its ad-hoc signature, so re-register launch at login.
"$APP/Contents/MacOS/FableUsage" --login on

open "$APP"
echo "Installed and launched $APP"
