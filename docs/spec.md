# Insomnia — keep the Mac awake and working with the lid closed

## Purpose

Coding agents (T3 Code, Conductor, Claude Code, Codex) keep running while the
MacBook is closed and in a bag. Insomnia is a menu bar app that:

1. Prevents lid-close sleep for a fixed, user-chosen duration. Never a toggle.
2. Cuts battery waste while the lid is closed without slowing the agents.
3. Shortens Wi-Fi to hotspot handoffs so agent API retries succeed.
4. Always restores the machine to normal, even if Insomnia crashes or is killed.

## Non-goals

- Not a kernel extension, not a signed privileged helper, not distributed.
  Personal tool, ad-hoc signed, installed by a script.
- Does not manage or restart the agents themselves. The only agent interaction
  is an optional "continue" keystroke into tagged tmux panes.
- Does not touch sleep behaviour outside an active session.
- No polling loops. Every input is an OS event (see "Event sources").

## Platform

- macOS 26 on Apple Silicon (built and tested on MacBook Pro M5).
- Swift 6, SwiftUI `MenuBarExtra`, Swift Package. No Xcode project.
- `install.sh` assembles a minimal `Insomnia.app` bundle (`LSUIElement = true`,
  no Dock icon), ad-hoc codesigns it, and installs it to `~/Applications`.

## Core model

```
Session {
  startedAt:   Date
  endsAt:      Date          // the only thing that keeps sleep disabled
  extendedBy:  [TimeInterval]
}

RuntimeState {                // everything Insomnia changed and must undo
  sleepDisabledByUs:  Bool
  lowPowerSetByUs:    Bool
  frozenPids:         [Int32]
  dockerFrozen:       Bool
  savedOutputVolume:  Float?  // nil when mute is off or lid is open
  savedMuted:         Bool?
}
```

Both are written to `~/Library/Application Support/Insomnia/` as JSON on every
change. They are the source of truth for reconcile and for the backstop.

## Features

### 1. Timed sessions (the only way to keep the Mac awake)

- Time is entered inline in the menu bar as Days / Hours / Minutes pills
  (section 11), or with one click on a preset chip: 30m, 1h, 2h, 4h, 8h,
  12h, 24h, 3d. Presets are editable in settings. Maximum 30 days.
- While active the menu bar shows the remaining time at minute granularity
  ("2h 14m"). The redraw timer ticks once per minute and stops entirely while
  the lid is closed.
- Popover while active: ends-at time, Extend (+30m, +1h, +4h, custom), End now.
- Session start: write session + state to disk first, then
  `sudo pmset -a disablesleep 1`. If pmset fails, delete the session file and
  surface the error. The journal always exists before sleep is disabled, so a
  crash between the two steps leaves a record the backstop can act on.
- Session end (timer, End now, Quit, battery floor, thermal critical):
  `sudo pmset -a disablesleep 0`, undo every RuntimeState entry, delete
  session, notify.
- Quitting Insomnia always ends the session. There is no "keep awake after quit".

### 2. Sleep guard and root access

- `install.sh` writes `/etc/sudoers.d/insomnia` allowing the user to run,
  without a password, exactly:
  - `/usr/bin/pmset -a disablesleep 1`
  - `/usr/bin/pmset -a disablesleep 0`
  - `/usr/bin/pmset -b lowpowermode 1`
  - `/usr/bin/pmset -b lowpowermode 0`
- Nothing else runs as root.

### 3. Lid observer

- IOKit interest notification on `IOPMrootDomain` for `AppleClamshellState`.
  Insomnia sleeps in its run loop; the kernel wakes it on change. Zero cost
  between events.
- 2-second debounce to ignore flapping.
- Lid close and open each run a fixed, reversible action list (below).
- Lid events do nothing when no session is active.

### 4. Lid-close actions (battery)

All actions are recorded in RuntimeState and reversed on lid open, session end,
Quit, or reconcile.

| action | on close | on open |
|---|---|---|
| Freeze list | `SIGSTOP` every process whose responsible app is in the list | `SIGCONT` the recorded pids only |
| Docker rule | if Docker Desktop is running and `docker ps -q` is empty, freeze it | resume |
| Mute (optional) | save volume and mute state, then mute | restore both exactly |
| Countdown redraw | stop timer | restart timer |

Freeze list rules:

- User picks apps by bundle id from a list of currently running apps.
- Hard denylist that can never be frozen: `com.apple.*`, Insomnia itself,
  Docker Desktop (handled by the Docker rule), and any bundle id in the
  agent list (below).
- Only pids Insomnia stopped are resumed. An app launched while the lid is
  closed is left alone.
- Electron apps are stopped as a whole process tree (main + helpers), found
  via the responsible-pid relationship, so no helper keeps spinning.

Not done on lid close, because it saves nothing: display brightness (panel is
already off by hardware), keyboard backlight (same), Bluetooth (needed for
Instant Hotspot, and negligible).

### 5. Agent apps: keep them fast

- Agent list (bundle ids, default: T3 Code, Conductor, Terminal, iTerm,
  Ghostty, Warp, Chrome, Chromium, Arc, Docker Desktop). Editable.
- On session start Insomnia sets `NSAppSleepDisabled = YES` for each listed app
  so App Nap never throttles them. This is a persistent per-app default and is
  left in place; it is harmless when no session is running.
- Browser throttling: Chromium browsers throttle windows macOS reports as
  occluded, which is every window once the lid is closed with no external
  display. Timers drop to 1 Hz, animation frames stop, pages report hidden.
  This can break computer-use and browser-use agents.
  - Insomnia inspects running Chromium processes for
    `--disable-backgrounding-occluded-windows` and
    `--disable-renderer-backgrounding`.
  - If a browser is running without them, the menu shows a warning and a
    "Relaunch <browser> unthrottled" item that quits and relaunches it with
    both flags and the same profile.
  - Headless Playwright is unaffected and needs nothing.
  - **Must be verified on the real machine with the lid shut** (see test plan).
    If macOS 26 does not mark windows occluded in this state, the feature is
    reduced to the App Nap default and the warning is removed.

### 6. Battery and thermal floors

Event sources: `IOPSNotificationCreateRunLoopSource` (fires on every battery
percentage change) and `ProcessInfo.thermalStateDidChangeNotification`.

| condition | action | undo |
|---|---|---|
| battery below `lowPowerFloor` (default 40%) | `pmset -b lowpowermode 1` | charger connected, or session end |
| battery below `endFloor` (default 10%) | end session, notify | — |
| thermal state `serious` | `lowpowermode 1` | thermal back to `nominal`/`fair`, or session end |
| thermal state `critical` | end session, notify | — |

Low Power Mode is never on by default. It slows local builds and tests by
roughly a fifth to a third and does not affect model speed, so it is used only
to stretch a low battery or cool a hot bag.

### 7. Network failover

- `NWPathMonitor` on the Wi-Fi interface. Event-driven.
- Path unsatisfied for more than 5 s: run
  `networksetup -setairportnetwork <iface> <hotspotSSID> <password>`.
  Password is read from the login Keychain (item `insomnia-hotspot`).
  Retry with backoff (5 s, 10 s, 20 s, 30 s, then every 30 s) until the path
  is satisfied or the session ends.
- Each outage is logged with start, end, and gap length to
  `~/Library/Logs/Insomnia/handoffs.log`. The menu shows the last gap.
- Path satisfied again after a gap longer than `nudgeThreshold` (default 90 s):
  - For every tagged tmux target (`session:window.pane`), run
    `tmux send-keys -t <target> "continue" Enter`.
  - Post a notification: "Network was down 2m 10s. Nudged 2 tmux panes.
    Check GUI agents."
- Recommended one-time setting, documented in the README: System Settings >
  Wi-Fi > "Ask to join hotspots" = Automatically.

### 8. Reconcile and backstop (always restore)

Invariants:

- Sleep is never disabled unless a session file with a future `endsAt` exists.
- Every change Insomnia makes is in RuntimeState before it is made, and is
  undone from RuntimeState, never from memory.

Reconcile runs at every Insomnia launch:

1. Session file missing or expired → run full session end (restore sleep,
   `SIGCONT` recorded pids, unset Low Power Mode if we set it, restore volume).
2. Session valid → re-apply `disablesleep 1` (idempotent), resume observers,
   and if the lid is currently open, undo any lid-close actions still recorded.
3. `pmset -g` reports `SleepDisabled 1` with no session → set it to 0.

Backstop, independent of the app:

- launchd agent `com.insomnia.backstop`, `RunAtLoad = true`, plus a
  `StartCalendarInterval` that Insomnia rewrites to the current `endsAt` on every
  session start or extend.
- It runs `scripts/backstop.sh`, which does step 1 above using only the JSON
  files and the sudoers-allowed commands. No Swift, no Insomnia process needed.
- Covers: Insomnia crash, force quit, `kill -9`, reboot mid-session, login after
  a reboot.

### 9. Notifications

`UNUserNotificationCenter`: session ended (with reason), extend reminder 5
minutes before end, battery floor reached, thermal action taken, network gap
recovered (with nudge summary), sleep restored by backstop.

### 10. Settings

JSON at `~/Library/Application Support/Insomnia/config.json`, edited through a
small settings window:

- presets, default preset
- freeze list (bundle ids), Docker rule on/off, mute on lid close on/off
- agent list (bundle ids)
- `lowPowerFloor`, `endFloor`, thermal rules on/off
- hotspot SSID (password entered once, stored in Keychain), `nudgeThreshold`
- tmux targets
- launch at login (`SMAppService.mainApp`)

### 11. Menu bar UI: inline time entry

Reference: the attached screenshot (coffee icon, then three rounded pill
fields "Hours", "Minutes", "Seconds", each with a small "?" badge, sitting
directly in the menu bar). Insomnia copies that interaction and the feel.

**Idle state.** A single coffee-cup status item. Nothing else in the bar.

**Entering a time.** Click the icon and the status item *expands in place*
along the menu bar: three pill fields spring out to the right of the icon,
one after another with a short stagger.

```
☕  ( Days ? ) ( Hours ? ) ( Minutes ? )
```

- Days · Hours · Minutes rather than the reference's Hours · Minutes · Seconds.
  Seconds are meaningless for keeping a laptop awake and days are needed.
  (Flip this in one line if you want the reference exactly.)
- Each pill is a numeric field. Placeholder text is the unit name; typing
  replaces it with the number and the pill grows to fit. Tab and Shift-Tab
  move between pills, Enter starts the session, Esc collapses.
- The "?" badge on each pill is a help affordance: hover shows a tooltip
  ("Up to 30 days" etc.). It is not an input.
- A row of preset chips (30m, 1h, 2h, 4h, 8h, 12h, 24h, 3d) sits in a
  small popover under the pills for one-click starts. Clicking a chip fills
  the pills, which then animate into the running state.

**Running state.** On Enter the pills collapse and morph into a compact
countdown next to the icon: `☕ 2h 14m`. Clicking the countdown opens a
popover with: ends-at time, Extend chips (+30m, +1h, +4h), End now, the status
lines (lid, watts, Wi-Fi, frozen apps, Docker), the Chrome throttle warning
with its relaunch button, Settings…, and Quit.

Battery watts are read from `AppleSmartBattery` (`InstantAmperage` ×
`Voltage`) only when the popover is opened. Never polled.

**Motion and feel.** This is a hard requirement, not polish.

- Everything animates with springs, never linear or ease curves.
  Baseline: `.spring(response: 0.35, dampingFraction: 0.72)`; pill focus
  bounce and chip taps use a snappier `.spring(response: 0.25,
  dampingFraction: 0.6)` with a slight scale overshoot (1.0 → 1.06 → 1.0).
- The status item width change is animated too, so the menu bar
  neighbours slide over smoothly instead of jumping. Implemented as a custom
  `NSStatusItem` view whose intrinsic width is driven by the SwiftUI layout.
- Pills appear with a staggered scale-and-fade (about 40 ms between pills).
  Collapsing reverses the stagger.
- Pill to countdown uses a matched-geometry morph, so the text visually
  flows from the field into the countdown rather than cutting.
- Number changes in the countdown use `.contentTransition(.numericText())`.
- Focus ring is a soft glow that breathes in, not a hard outline.
- Respect Reduce Motion: springs become short crossfades.
- Rendering matches the reference: dark rounded pills with a subtle
  material, system font, SF Symbols icon, no custom images.

Reference for taste: Apple's own Dynamic Island and Control Center
transitions. If it feels like a web dropdown, it is wrong.

## Event sources (complete list)

| input | mechanism | cost between events |
|---|---|---|
| lid | IOKit interest notification | none |
| battery % | IOPS run loop source | none |
| thermal | `ProcessInfo` notification | none |
| network path | `NWPathMonitor` | none |
| session deadline | one `Timer` at `endsAt` + launchd calendar backstop | none |
| countdown redraw | 60 s timer, stopped while lid closed | one wake per minute |
| hotspot retry | only during an outage | none otherwise |

## Repository layout

```
harbor/insomnia/
  Package.swift
  Sources/Insomnia/
    InsomniaApp.swift        MenuBarExtra, menu, settings window
    SessionManager.swift   start / extend / end / reconcile
    SleepGuard.swift       pmset via sudo, pmset -g parsing
    LidObserver.swift      IOKit clamshell notifications
    LidActions.swift       freeze / docker / mute, with undo
    Freezer.swift          process tree discovery, SIGSTOP / SIGCONT, denylist
    PowerMonitor.swift     battery %, watts on demand, thermal state
    NetworkFailover.swift  NWPathMonitor, networksetup, Keychain, handoff log
    TmuxNudge.swift
    BrowserThrottle.swift  flag detection, relaunch unthrottled
    AppNap.swift
    AudioControl.swift     CoreAudio default output volume + mute
    Notifier.swift
    Config.swift           config.json
    State.swift            session.json, state.json
    Log.swift
  Tests/InsomniaTests/
    SessionMathTests       durations, extend, expiry
    ReconcileTests         every RuntimeState combination restores cleanly
    FreezerTests           denylist, process-tree grouping (mocked)
    ConfigTests
  scripts/
    install.sh             build, bundle, codesign, sudoers, launchd, login item
    uninstall.sh           reverse all of the above, restore sleep
    backstop.sh            standalone restore from JSON
  docs/spec.md
  README.md                setup, hotspot setting, Chrome note
```

## Install

```
git clone … harbor && cd harbor/insomnia
./scripts/install.sh      # asks for sudo once, for the sudoers file
```

Then set the hotspot in Settings, pick a freeze list, and start a session.

## Manual test plan

Run on the real MacBook Pro before calling it done.

1. **Stays awake.** Start 30m session, close lid, wait 5 minutes, ping the Mac
   from the phone or check the heartbeat log. Open lid: session still running,
   sleep still disabled until end.
2. **Restores.** End now → `pmset -g` shows no `SleepDisabled`. Quit → same.
   Timer expiry → same, plus notification.
3. **Backstop.** Start session, `kill -9` Insomnia, wait for `endsAt` → sleep
   restored by launchd. Reboot mid-session → restored at login.
4. **Freeze.** Slack and WhatsApp on list, close lid, `ps -o stat` shows `T`
   for their whole trees. Open lid → running, reconnected, no relaunch.
5. **Docker rule.** No containers → paused on close. One container → untouched.
6. **Mute.** Volume 60%, close lid → muted. Open → 60%, unmuted.
7. **Chrome occlusion.** Lid closed, Playwright attached to headed Chrome:
   read `document.visibilityState` and measure `setInterval` drift. Repeat with
   both flags. Decide whether feature 5's browser section stays.
8. **Handoff.** Turn off the router or walk away, watch `handoffs.log`, confirm
   hotspot joined within ~10 s and a Claude Code turn in flight completes.
9. **Nudge.** Gap forced above threshold → tagged tmux pane receives
   "continue", notification posted.
10. **Floors.** Set `lowPowerFloor` above current charge → Low Power Mode on.
    Plug in charger → off. Set `endFloor` above current charge → session ends.
11. **Thermal.** Simulate with a CPU burner; `serious` → LPM on, back to
    `nominal` → off.

## Open decisions (defaults chosen, change if you disagree)

- `pmset -a` (all power sources) rather than `-b` for `disablesleep`, so
  behaviour is identical whether or not a charger is attached.
- Default `lowPowerFloor` 40%, `endFloor` 10%, `nudgeThreshold` 90 s.
- App Nap defaults are left set after a session ends.
