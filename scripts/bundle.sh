#!/bin/bash
# Builds a release binary and wraps it in "build/Copyisto Trimmer.app", so the app opens from Finder and the Dock.
# SwiftPM builds plain executables; the .app adds the icon, the bundled fonts and a proper app identity.
#
# VERSION        version shown in Finder (default 0.0.0-dev); CI passes the tag
# SIGN_IDENTITY  codesigning identity (default "-", ad hoc); CI passes "Developer ID Application" for notarised builds
set -euo pipefail
version="${VERSION:-0.0.0-dev}"
identity="${SIGN_IDENTITY:--}"
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/CopyistoTrimmer"

app="build/Copyisto Trimmer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/CopyistoTrimmer"
# Registered by ATSApplicationFontsPath below, so no font-loading code is needed.
cp -R Resources/Fonts "$app/Contents/Resources/Fonts"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# NSImage reads SVG and keeps the transparent corners (qlmanage paints them white).
swift -e '
import AppKit
let svg = NSImage(contentsOfFile: CommandLine.arguments[1])!
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
svg.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
' Resources/AppIcon.svg "$work/AppIcon.png"
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$work/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.copyisto.trimmer</string>
  <key>CFBundleName</key><string>Copyisto Trimmer</string>
  <key>CFBundleDisplayName</key><string>Copyisto Trimmer</string>
  <key>CFBundleExecutable</key><string>CopyistoTrimmer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleDevelopmentRegion</key><string>pl</string>
  <key>CFBundleLocalizations</key><array><string>pl</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "$identity" == "-" ]]; then
  # Ad hoc, so the bundle as a whole (not just the binary) is valid on Apple silicon.
  codesign --force --sign - "$app"
else
  # Hardened runtime and a secure timestamp are what notarisation requires.
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
echo "$app"
