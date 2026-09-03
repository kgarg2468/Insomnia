# Insomnia

A macOS menu bar app that keeps a MacBook awake with the lid closed for a
fixed, user-chosen time, so coding agents keep running in a bag. It always
restores sleep afterwards, even if it crashes: a launchd backstop reads the
same JSON journal and undoes everything.

Personal tool. Ad-hoc signed, not distributed. Full design in
[`docs/spec.md`](docs/spec.md).

## Install

Requires macOS 26 and Xcode 26 (Swift 6.3).

```
git clone https://github.com/kgarg2468/harbor && cd harbor/insomnia
./scripts/install.sh
```

The script builds a release binary, assembles `~/Applications/Insomnia.app`,
installs `backstop.sh` and a `com.insomnia.backstop` LaunchAgent, and writes
`/etc/sudoers.d/insomnia`. That sudoers file is the only privileged piece; it
lets your user run exactly four commands without a password:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -b lowpowermode 1
/usr/bin/pmset -b lowpowermode 0
```

Then `open ~/Applications/Insomnia.app` and pick a duration from the menu.

**First run:** run `./scripts/install.sh`, start a 30m session, close the lid,
then open `~/Library/Logs/Insomnia/insomnia.log` and check that the session and
lid-close actions were logged.

## Hotspot handoff

For fast Wi-Fi to iPhone hotspot failover, set
**System Settings > Wi-Fi > Ask to join hotspots** to **Automatically** once.
Enter the hotspot SSID and password in Insomnia Settings. The password is stored
as a generic password in the login Keychain under service `insomnia-hotspot`,
and Insomnia uses an SSID-filtered CoreWLAN scan to rejoin without putting the
password in process arguments.

macOS requires Location Services permission before CoreWLAN can reveal Wi-Fi
network names or find the configured SSID. Insomnia requests that permission on
the first hotspot save (or when a session starts with a hotspot already
configured), never merely because the app launched. If access was denied, use
the Location row in Settings to open **Privacy & Security > Location Services**.

## Chrome

Chromium browsers throttle windows macOS reports as occluded, which is every
window once the lid is closed. Insomnia detects a running Chrome, Chromium, or
Arc process missing `--disable-backgrounding-occluded-windows` or
`--disable-renderer-backgrounding` and offers **Relaunch unthrottled** in the
session popover. Relaunch preserves the browser profile arguments.

## What happens when the lid closes

During an active timed session, Insomnia optionally saves and mutes audio,
freezes only the configured non-agent apps and an idle Docker Desktop, and
pauses the countdown redraw. Opening the lid, ending the session, or quitting
restores the recorded processes and audio exactly from the on-disk journal.
Without an active session, lid changes do nothing.

## Files

```
~/Library/Application Support/Insomnia/   session.json, state.json, config.json, backstop.sh
~/Library/Logs/Insomnia/                  insomnia.log, handoffs.log
~/Library/LaunchAgents/                   com.insomnia.backstop.plist
/etc/sudoers.d/insomnia
```

Set `INSOMNIA_HOME` to relocate the first three into one directory (used by
the tests and by `backstop.sh`).

## Uninstall

```
./scripts/uninstall.sh          # restores sleep, removes agent, sudoers, app
./scripts/uninstall.sh --purge  # also removes config.json and logs
```

## Development

```
swift build
swift test
```
