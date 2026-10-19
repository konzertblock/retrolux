#!/bin/bash
# Builds the app, zips it, signs the zip with Sparkle's EdDSA key (keychain account "retrolux") and refreshes docs/appcast.xml.
# Afterwards: create the GitHub release v$VERSION with dist/release/Retrolux-$VERSION.zip and commit docs/appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
./scripts/make_app.sh
OUT=dist/release; rm -rf "$OUT"; mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent dist/Retrolux.app "$OUT/Retrolux-$VERSION.zip"
TOOLS="$(dirname "$(find .build/artifacts -name generate_appcast -path '*Sparkle/bin*' | head -1)")"
"$TOOLS/generate_appcast" --account retrolux \
  --download-url-prefix "https://github.com/konzertblock/retrolux/releases/download/v$VERSION/" \
  --link "https://github.com/konzertblock/retrolux" \
  -o docs/appcast.xml "$OUT"
echo "zip: $OUT/Retrolux-$VERSION.zip  appcast: docs/appcast.xml"
