#!/bin/bash
# Build Insomnia, assemble ~/Applications/Insomnia.app, install the backstop
# script + LaunchAgent, and write the sudoers rule. Idempotent; asks for sudo
# once (for /etc/sudoers.d/insomnia).
set -euo pipefail

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
if pgrep -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia is running; quitting it first (this ends any session)."
  osascript -e 'tell application id "com.kgarg.insomnia" to quit' >/dev/null 2>&1 || pkill -x Insomnia || true
  sleep 2
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
if sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  echo "sudoers rule verified"
else
  echo "warning: 'sudo -n pmset' still fails; check $SUDOERS" >&2
fi

# 5. LaunchAgent (RunAtLoad only; the app adds the calendar trigger) ---------
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
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

# 6. Done --------------------------------------------------------------------
step "Installed"
cat <<NEXT
Next steps:
  1. Launch:            open "$APP"
  2. Optional:          System Settings > Wi-Fi > Ask to join hotspots: Automatically
  3. Config lives at:   $APP_SUPPORT/config.json
  4. Logs:              $LOG_DIR/insomnia.log
  5. Uninstall:         $ROOT/scripts/uninstall.sh
NEXT
