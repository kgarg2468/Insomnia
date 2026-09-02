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

## Hotspot handoff

For fast Wi-Fi to iPhone hotspot failover, set
**System Settings > Wi-Fi > Ask to join hotspots** to **Automatically** once.
Insomnia's own failover (hotspot SSID in `config.json`, password in the login
Keychain as `insomnia-hotspot`) lands in a later release.

## Chrome

Chromium browsers throttle windows macOS reports as occluded, which is every
window once the lid is closed. If a browser-driving agent stalls with the lid
shut, relaunch Chrome with
`--disable-backgrounding-occluded-windows --disable-renderer-backgrounding`.
Insomnia will offer a one-click "Relaunch unthrottled" in a later release.

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
