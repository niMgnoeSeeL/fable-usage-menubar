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

# bash 3.2 + `set -u` treats an empty array as unbound, hence the ${...+...} form.
swiftc_() { swiftc -O -swift-version 5 ${OVERLAY_FLAGS[@]+"${OVERLAY_FLAGS[@]}"} "$@"; }

# The icon is committed; delete AppIcon.icns to regenerate it from icon/make_icon.swift.
if [[ ! -f AppIcon.icns ]]; then
  swiftc_ -o build/make_icon icon/make_icon.swift
  rm -rf build/AppIcon.iconset
  build/make_icon build/AppIcon.iconset icon/preview.png
  iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi

swiftc_ -o build/FableUsage main.swift

pkill -x FableUsage 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp build/FableUsage "$APP/Contents/MacOS/FableUsage"
codesign --force --sign - "$APP"
touch "$APP"  # nudge Finder/LaunchServices to pick up the new icon

# Reinstalling replaces the bundle and its ad-hoc signature, so re-register launch at login.
"$APP/Contents/MacOS/FableUsage" --login on

open "$APP"
echo "Installed and launched $APP"
