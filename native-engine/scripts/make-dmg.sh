#!/usr/bin/env bash
# Monta Rockport.dmg: la app nativa + el conversor de ISO compilado en un solo binario.
# No lleva ningún dato del juego: el jugador elige su ISO en el primer arranque (Installer.swift).
# Uso: native-engine/scripts/make-dmg.sh   →   native-engine/.build/Rockport-<versión>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
VERSION=$(cat VERSION 2>/dev/null || echo "0.1.0")

# 1) App (.build/Rockport.app)
bash scripts/make-app.sh
APP=.build/Rockport.app

# 2) Conversor: tools/src/cli/install.ts compilado con Bun para Apple Silicon
( cd "$ROOT/tools" && bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null )
bun build --compile --minify --target=bun-darwin-arm64 "$ROOT/tools/src/cli/install.ts" --outfile "$APP/Contents/Resources/rockport-convert"
chmod +x "$APP/Contents/Resources/rockport-convert"
# Sin firma, macOS mata el binario compilado al arrancar (exit 137)
codesign --force --sign - "$APP/Contents/Resources/rockport-convert"

# 3) Firma local (ad hoc). La firma Developer ID + notarización necesita una cuenta de Apple Developer (ver README).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# 4) DMG con la app y un acceso a /Applications
STAGE=.build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT=".build/Rockport-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Rockport $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Listo: native-engine/$OUT ($(du -h "$OUT" | cut -f1))"
