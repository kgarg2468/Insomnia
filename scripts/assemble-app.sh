#!/bin/bash
# Assemble and ad-hoc sign an Insomnia.app from an already-built executable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 /path/to/Insomnia.app /path/to/Insomnia-binary" >&2
  exit 64
fi

APP="$1"
BIN="$2"

if [[ "$(basename "$APP")" != "Insomnia.app" ]]; then
  echo "destination must end in Insomnia.app: $APP" >&2
  exit 64
fi
if [[ ! -x "$BIN" ]]; then
  echo "executable not found at $BIN" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Insomnia"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --deep "$APP"

