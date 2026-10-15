#!/usr/bin/env bash
# Monta native-engine/.build/Rockport.app a partir de `swift build -c release`.
# No incluye datos del juego ni el conversor todavía (ver README: "Camino al DMG").
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=.build/Rockport.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Rockport "$APP/Contents/MacOS/Rockport"
# Icono propio (scripts/app-icon.swift); al instalar el disco la app pone el del juego (AppIcon.swift)
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/app-icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
VERSION=$(cat VERSION 2>/dev/null || echo "0.1.0")
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Rockport</string>
  <key>CFBundleDisplayName</key><string>Rockport</string>
  <key>CFBundleIdentifier</key><string>org.rockport.native</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Rockport</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.racing-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GCSupportsControllerUserInteraction</key><true/>
</dict>
</plist>
PLIST
# Firma local (ad hoc) para que macOS lo abra en este Mac. La firma con Developer ID y la notarización van aparte.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Listo: $APP"
