#!/bin/bash
# Build Insomnia, assemble ~/Applications/Insomnia.app, install the backstop
# script + LaunchAgent, and write the sudoers rule. Idempotent; asks for sudo
# once (for /etc/sudoers.d/insomnia).
set -euo pipefail

# Installation always uses the standard per-user layout. A relocated
# INSOMNIA_HOME would make the backstop run here act on one tree while the
# app is installed against another, so refuse rather than guess.
if [[ -n "${INSOMNIA_HOME:-}" ]]; then
  echo "INSOMNIA_HOME is set ($INSOMNIA_HOME). install.sh only supports the standard layout under ~/Library;" >&2
  echo "unset INSOMNIA_HOME and rerun. Nothing was changed." >&2
  exit 1
fi

# How long to wait for the app to exit after asking it to quit.
QUIT_WAIT_SECONDS=15

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Insomnia.app"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
LOG_DIR="$HOME/Library/Logs/Insomnia"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABEL="com.insomnia.backstop"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
SUDOERS=/etc/sudoers.d/insomnia
UID_NUM="$(id -u)"

step() { printf '\n==> %s\n' "$*"; }

# 1. Build -------------------------------------------------------------------
step "Building (release)"
cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Insomnia"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

# 2. Bundle ------------------------------------------------------------------
step "Assembling $APP"
# Ask the app to quit and wait until it has actually exited. It refuses to
# quit while it has unresolved recovery work; that refusal stands (no pkill),
# and nothing of the old install is overwritten while it is still running.
if pgrep -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia is running; quitting it first (this ends any session)."
  osascript -e 'tell application id "com.kgarg.insomnia" to quit' >/dev/null 2>&1 || true
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    pgrep -x Insomnia >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -x Insomnia >/dev/null 2>&1; then
    echo "Insomnia is still running after ${QUIT_WAIT_SECONDS}s (it may be refusing to quit until its own recovery finishes)." >&2
    echo "Let it finish or quit it from its menu, then rerun. Nothing was changed." >&2
    exit 1
  fi
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Insomnia"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --deep "$APP"
echo "signed $(codesign -dv "$APP" 2>&1 | grep -i identifier || true)"

# 3. Backstop script + dirs --------------------------------------------------
step "Installing backstop.sh to $APP_SUPPORT"
mkdir -p "$APP_SUPPORT" "$LOG_DIR" "$LAUNCH_AGENTS"
cp "$ROOT/scripts/backstop.sh" "$APP_SUPPORT/backstop.sh"
chmod +x "$APP_SUPPORT/backstop.sh"

# 4. sudoers -----------------------------------------------------------------
step "Writing $SUDOERS (requires your password once)"
TMP_SUDOERS="$(mktemp)"
trap 'rm -f "$TMP_SUDOERS"' EXIT
cat > "$TMP_SUDOERS" <<SUDO
# Installed by Insomnia install.sh. Exactly four commands, nothing else.
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0
SUDO
if sudo visudo -cf "$TMP_SUDOERS" >/dev/null; then
  sudo install -m 0440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS"
else
  echo "sudoers file failed validation; not installed" >&2
  exit 1
fi
# `sudo -l <command>` checks the rule without running pmset (nothing on the
# machine changes). The backstop cannot undo anything without it, so stop here.
if sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  echo "sudoers rule verified"
else
  echo "'sudo -n pmset' is still not permitted; check $SUDOERS. Not installing the agent." >&2
  exit 1
fi

# 5. Undo anything a previous install left journaled, with the backstop just
#    installed. sudoers is in place now, so pmset works without a prompt.
#    A failure is reported after the agent is in place (so it keeps retrying)
#    rather than ignored.
step "Ending any stale session and checking the recovery journal"
recovery_rc=0
/bin/bash "$APP_SUPPORT/backstop.sh" --force || recovery_rc=$?

# 6. LaunchAgent: runs the backstop at load and every 60 s. The backstop
#    enforces the saved deadline itself and is a no-op while the session on
#    disk is valid. The app writes the same plist (LaunchdBackstop.swift).
step "Installing LaunchAgent $LABEL"
launchctl bootout "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1 || true
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$APP_SUPPORT/backstop.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>60</integer>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

if (( recovery_rc != 0 )); then
  cat >&2 <<FAIL

Install stopped: the backstop could not fully undo a previous session
(exit status $recovery_rc). The app, backstop, sudoers rule, and LaunchAgent
are installed, and the agent retries every minute. Check
$LOG_DIR/insomnia.log, resolve what it reports (saved audio needs the app:
open "$APP"), then rerun this script.
FAIL
  exit 1
fi

# 7. Done --------------------------------------------------------------------
step "Installed"
cat <<NEXT
Next steps:
  1. Launch:            open "$APP"
  2. Optional:          System Settings > Wi-Fi > Ask to join hotspots: Automatically
  3. Config lives at:   $APP_SUPPORT/config.json
  4. Logs:              $LOG_DIR/insomnia.log
  5. Uninstall:         $ROOT/scripts/uninstall.sh
NEXT
