#!/bin/zsh
# build/DopaPachinko.app を作る
set -euo pipefail
cd "$(dirname "$0")"
APP=build/DopaPachinko.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/DopaPachinko" \
  -framework Cocoa -framework AVFoundation
# setup-signing.sh で作った証明書があればそれで署名する（作り直しても許可が残る）
if security find-identity -p codesigning | grep -q "DopaPachinko Dev"; then
  codesign --force --sign "DopaPachinko Dev" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "built: $PWD/$APP"
