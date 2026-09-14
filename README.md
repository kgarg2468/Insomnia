# Insomnia

A macOS menu bar app for keeping a MacBook awake for a fixed, user-chosen
time. A recovery journal and launchd backstop support restoring changed
settings when the session ends or the app exits unexpectedly.

Experimental, source-built software. The local app is ad-hoc signed, not a
Developer ID-signed or notarized consumer download. See the
[release validation record](docs/release-validation.md) for what has and has
not been tested, and [design notes](docs/spec.md) for implementation context.

## Safety and recovery limits

Use a stable, well-ventilated surface. **Do not run an awake MacBook inside a
closed bag or other poorly ventilated enclosure.** See
[Apple's operating-temperature guidance](https://support.apple.com/en-us/102336).

Battery and thermal session rules require the Insomnia app to be running.
The independent backstop is not a battery or thermal monitor. A countdown or
journal entry is not proof of safe temperature, sufficient battery, or the
current operating-system power state. Recovery can fail when permissions,
disk access, or system commands fail; inspect any recovery warning before
leaving the machine unattended.

After a crash, saved audio settings require reopening the app; the shell
backstop preserves them but cannot restore CoreAudio itself. Legacy stopped
processes without recorded identity also need app or manual resolution.
Uninstall refuses to remove recovery tools while unresolved changes remain.
Process identity checks reduce PID-reuse risk but are not atomic with sending
a signal; the shell checks start time only to the second, while the app also
checks microseconds. Both check the boot session.

If a timed-out power command cannot be stopped, recovery deliberately keeps
the lock until that command exits. New sessions and other recovery attempts
wait or fail with a lock warning; they do not proceed beside a command that
may still change power settings. Inspect the log and the current process
before taking manual action—do not blindly signal a PID from an old log.

App Nap defaults for configured agent apps intentionally persist after a
session ends and after uninstall. Recovery does not promise to undo every
preference change. Hardware crash, reboot, lid-close, and hotspot scenarios
remain release-validation requirements, not guarantees inferred from CI.

## Install

Requires macOS 26 and Xcode 26 (Swift 6.3).

```
git clone https://github.com/kgarg2468/Insomnia.git && cd Insomnia
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

Then `open ~/Applications/Insomnia.app`, click the cup, enter Days / Hours /
Minutes, and press Enter. While running, click the cup or countdown to extend
the duration. Right-click for status, Settings, and Quit.

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

Configured tmux targets opt into sending `continue` followed by Enter after a
long outage. Use dedicated, disposable agent panes: Insomnia cannot determine
whether the foreground program already has unsent text, and Enter can submit
that text too. Removing targets disables this automation. Stopping a session
cannot retract keystrokes already delivered.

## Chrome

Chromium browsers throttle windows macOS reports as occluded, which is every
window once the lid is closed. Insomnia detects a running Chrome, Chromium, or
Arc process missing `--disable-backgrounding-occluded-windows` or
`--disable-renderer-backgrounding` and offers **Relaunch unthrottled** in the
right-click menu. Relaunch preserves the browser profile arguments.

## What happens when the lid closes

During an active timed session, Insomnia optionally saves and mutes audio,
freezes only the configured non-agent apps and an idle Docker Desktop, and
pauses the countdown redraw. Opening the lid, ending the session, or quitting
attempts to restore the recorded processes and audio from the on-disk journal.
Without an active session, lid changes do nothing.

Docker's idle result is a point-in-time check, not a transaction with container
startup. Leave the Docker rule disabled when pausing a newly started container
would interrupt important work.

## Files

```
~/Library/Application Support/Insomnia/   session.json, state.json, config.json, backstop.sh
~/Library/Logs/Insomnia/                  insomnia.log, handoffs.log
~/Library/LaunchAgents/                   com.insomnia.backstop.plist
/etc/sudoers.d/insomnia
```

Set `INSOMNIA_HOME` to relocate the first three into one directory (used by
the app's tests and by `backstop.sh`). Do not treat this as an installation
sandbox: the installation scripts also operate on the app, LaunchAgent, and
sudoers locations above.

## Uninstall

```
./scripts/uninstall.sh          # restores sleep, removes agent, sudoers, app
./scripts/uninstall.sh --purge  # also removes config.json and logs
```

Uninstall stops if recovery is incomplete or the app refuses to quit. Resolve
the reported problem before retrying. Purge removes Insomnia-owned files,
not arbitrary directory contents; a small shared lock file is retained to
avoid splitting the recovery lock between concurrent processes.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for safe testing boundaries and
[SECURITY.md](SECURITY.md) for reporting suspected vulnerabilities.

```
swift build
swift test
```
