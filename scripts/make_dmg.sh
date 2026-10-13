#!/usr/bin/env bash
# Packages a built Upright.app into an unsigned, compressed disk image with an
# Applications shortcut. Usage: scripts/make_dmg.sh [path/to/Upright.app] [output.dmg]
set -euo pipefail

APP="${1:-build/Build/Products/Release/Upright.app}"
OUT="${2:-dist/Upright.dmg}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Build the app first (make app)." >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "Upright" -srcfolder "$STAGING" -ov -format UDZO "$OUT"
echo "Created $OUT"
