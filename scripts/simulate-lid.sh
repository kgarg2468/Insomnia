#!/bin/bash
# Drive Insomnia's lid-close action path without touching the hinge, for
# release validation (docs/release-validation.md) on a machine whose lid has
# to stay open. Writes "closed" or "open" to APP_SUPPORT/simulate-lid; the
# running app (LidSimulation.swift) reads and deletes the file and runs the
# same actions a real lid event would: darken the display and keyboard
# backlight, mute, freeze, pause Docker, and the reverse on "open".
#
# Same trust boundary as config.json: anyone who can write the support
# directory already controls the app. The app only acts on the trigger
# while a session is active; otherwise the file is consumed and ignored at
# the next session start, so run this only during a session.
#
# Honours INSOMNIA_HOME with the same layout as the app (see Paths.swift).
set -euo pipefail

APP_SUPPORT="${INSOMNIA_HOME:-$HOME/Library/Application Support/Insomnia}"
TRIGGER="$APP_SUPPORT/simulate-lid"

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") closed|open

Writes the lid event to "$TRIGGER" for a running Insomnia
session to act on. Set INSOMNIA_HOME to target a relocated support dir.
USAGE
  exit 2
}

[[ $# -eq 1 ]] || usage
case "$1" in
  closed|open) event="$1" ;;
  *) usage ;;
esac

[[ -d "$APP_SUPPORT" ]] || { echo "no support directory at $APP_SUPPORT; is Insomnia installed?" >&2; exit 1; }

# Write next to the target and rename, so the watcher never reads a
# half-written or empty file.
tmp="$APP_SUPPORT/.simulate-lid.tmp.$$"
printf '%s\n' "$event" > "$tmp"
mv -f "$tmp" "$TRIGGER"
echo "lid $event: trigger written to $TRIGGER"
