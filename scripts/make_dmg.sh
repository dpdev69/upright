#!/usr/bin/env bash
# Packages a built Upright.app into a compressed disk image with an Applications
# shortcut (the image itself is unsigned; sign/notarize it afterwards if needed).
# Usage: scripts/make_dmg.sh [path/to/Upright.app] [output.dmg] [volume name]
set -euo pipefail

APP="${1:-build/Build/Products/Release/Upright.app}"
OUT="${2:-dist/Upright.dmg}"
VOLNAME="${3:-Upright}"

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

# hdiutil can fail with "Resource busy" while Spotlight or the Finder still
# holds the staging folder; detach any stale mount of the same volume and retry.
attempt=1
max_attempts=5
until hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$OUT"; do
  if (( attempt >= max_attempts )); then
    echo "error: hdiutil create failed after $max_attempts attempts" >&2
    exit 1
  fi
  echo "hdiutil create failed (attempt $attempt/$max_attempts); retrying..." >&2
  if [[ -d "/Volumes/$VOLNAME" ]]; then
    hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null \
      || hdiutil detach "/Volumes/$VOLNAME" -force -quiet 2>/dev/null || true
  fi
  rm -f "$OUT"
  sleep $(( attempt * 2 ))
  attempt=$(( attempt + 1 ))
done
echo "Created $OUT"
