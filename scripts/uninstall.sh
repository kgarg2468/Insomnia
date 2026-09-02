#!/bin/bash
# Reverse install.sh. Restores sleep first, then removes the LaunchAgent,
# the sudoers rule, and the app bundle. Keeps config.json unless --purge.
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help) echo "usage: $0 [--purge]"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Applications/Insomnia.app"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
LOG_DIR="$HOME/Library/Logs/Insomnia"
LABEL="com.insomnia.backstop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUDOERS=/etc/sudoers.d/insomnia
UID_NUM="$(id -u)"

step() { printf '\n==> %s\n' "$*"; }

step "Quitting Insomnia"
if pgrep -x Insomnia >/dev/null 2>&1; then
  osascript -e 'tell application id "com.kgarg.insomnia" to quit' >/dev/null 2>&1 || pkill -x Insomnia || true
  sleep 2
fi

step "Restoring sleep via backstop"
rm -f "$APP_SUPPORT/session.json"
if [[ -x "$APP_SUPPORT/backstop.sh" ]]; then
  bash "$APP_SUPPORT/backstop.sh" || true
else
  bash "$ROOT/scripts/backstop.sh" || true
fi

step "Removing LaunchAgent"
launchctl bootout "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

step "Removing $SUDOERS (requires your password)"
if [[ -e "$SUDOERS" ]] || sudo test -e "$SUDOERS"; then
  sudo rm -f "$SUDOERS"
fi

step "Removing app bundle"
rm -rf "$APP"

if (( PURGE == 1 )); then
  step "Purging $APP_SUPPORT and $LOG_DIR"
  rm -rf "$APP_SUPPORT" "$LOG_DIR"
else
  rm -f "$APP_SUPPORT/backstop.sh" "$APP_SUPPORT/session.json" "$APP_SUPPORT/state.json"
  echo "Kept $APP_SUPPORT/config.json and $LOG_DIR (use --purge to remove)."
fi

echo "Done."
