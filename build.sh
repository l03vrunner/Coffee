#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
app="$root/Coffee.app"
macos="$app/Contents/MacOS"
resources="$app/Contents/Resources"
sdk="$(xcrun --show-sdk-path)"
arch="$(uname -m)"
target="${arch}-apple-macos14"
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
iconset="$root/build/AppIcon.iconset"
master="$root/build/icon-1024.png"
icns="$resources/AppIcon.icns"

rm -rf "$app" "$root/build"
mkdir -p "$macos" "$resources" "$iconset"

"$ictool" "$root/AppIcon.icon" \
  --export-image --output-file "$master" \
  --platform macOS --rendition Default \
  --width 1024 --height 1024 --scale 1 >/dev/null

sizes=(16 32 128 256 512)
for size in $sizes; do
  sips -z $size $size "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z $retina $retina "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$icns"

swiftc -O -parse-as-library \
  "$root/Sources/Coffee.swift" \
  -o "$macos/Coffee" \
  -target "$target" \
  -sdk "$sdk" \
  -framework AppKit \
  -framework Carbon \
  -framework IOKit \
  -framework ServiceManagement

cp "$root/Info.plist" "$app/Contents/Info.plist"
echo -n "APPL????" > "$app/Contents/PkgInfo"
chmod +x "$macos/Coffee"
codesign --force --sign - --identifier local.coffee "$app" >/dev/null

echo "Bygget $app"
