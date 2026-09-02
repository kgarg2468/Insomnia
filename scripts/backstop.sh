#!/bin/bash
# Insomnia backstop: restore the machine from the JSON journal alone.
# Runs from launchd (RunAtLoad + a calendar trigger at the session deadline)
# and from uninstall.sh. Needs no Insomnia process and no Swift.
#
# If session.json is missing, unreadable, or its endsAt is in the past:
#   - pmset -a disablesleep 0             (sudoers-allowed)
#   - pmset -b lowpowermode 0             (only if state.json says we set it)
#   - kill -CONT every pid in frozenPids  (errors ignored)
#   - delete session.json, rewrite state.json as clean
# Otherwise do nothing and exit 0. Safe to run repeatedly.
#
# Honours INSOMNIA_HOME with the same layout as the app (see Paths.swift).
set -euo pipefail

if [[ -n "${INSOMNIA_HOME:-}" ]]; then
  APP_SUPPORT="$INSOMNIA_HOME"
  LOG_DIR="$INSOMNIA_HOME/Logs"
else
  APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
  LOG_DIR="$HOME/Library/Logs/Insomnia"
fi
SESSION="$APP_SUPPORT/session.json"
STATE="$APP_SUPPORT/state.json"
LOG="$LOG_DIR/insomnia.log"
PMSET=/usr/bin/pmset
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil

log() {
  mkdir -p "$LOG_DIR"
  printf '%s [%s] backstop: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG"
}

# plutil -extract <key> raw prints the scalar; returns non-zero if missing.
extract() { # file key
  "$PLUTIL" -extract "$2" raw -o - "$1" 2>/dev/null
}

# Decide whether the session is still valid.
valid=0
if [[ -f "$SESSION" ]]; then
  ends_at="$(extract "$SESSION" endsAt || true)"
  if [[ -n "$ends_at" ]]; then
    # Store.swift writes ISO 8601 UTC without fractional seconds.
    ends_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ends_at" +%s 2>/dev/null || true)"
    now_epoch="$(date -u +%s)"
    if [[ -n "$ends_epoch" ]] && (( ends_epoch > now_epoch )); then
      valid=1
    fi
  fi
fi

if (( valid == 1 )); then
  exit 0
fi

# --- Restore -----------------------------------------------------------------

if [[ -f "$SESSION" ]]; then
  log info "session expired or unreadable (endsAt=${ends_at:-?}); restoring"
else
  log info "no session; restoring"
fi

low_power="$(extract "$STATE" lowPowerSetByUs 2>/dev/null || echo false)"
pids="$("$PLUTIL" -extract frozenPids json -o - "$STATE" 2>/dev/null | tr -c '0-9' ' ' || true)"

if "$SUDO" -n "$PMSET" -a disablesleep 0 2>/dev/null; then
  log info "pmset -a disablesleep 0 ok"
else
  log error "pmset -a disablesleep 0 failed (sudoers rule missing? run install.sh)"
fi

if [[ "$low_power" == "true" ]]; then
  if "$SUDO" -n "$PMSET" -b lowpowermode 0 2>/dev/null; then
    log info "pmset -b lowpowermode 0 ok"
  else
    log error "pmset -b lowpowermode 0 failed"
  fi
fi

resumed=0
for pid in $pids; do
  if kill -CONT "$pid" 2>/dev/null; then
    resumed=$((resumed + 1))
  fi
done
if [[ -n "${pids// /}" ]]; then
  read -r -a pid_list <<< "$pids"
  log info "SIGCONT sent to $resumed pid(s) of: ${pid_list[*]}"
fi

rm -f "$SESSION"
mkdir -p "$APP_SUPPORT"
tmp="$(mktemp "$APP_SUPPORT/.state.json.tmp-XXXXXX")"
cat > "$tmp" <<'JSON'
{
  "dockerFrozen" : false,
  "frozenPids" : [

  ],
  "lowPowerSetByUs" : false,
  "sleepDisabledByUs" : false
}
JSON
mv -f "$tmp" "$STATE"
log info "journal cleared"
exit 0
