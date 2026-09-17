# Menu bar smoothness: one width change per open and close

Date: 2026-09-17. Status: approved by the owner (direction B, "keep inline, fix the jank").

## Problem

Clicking the mark, typing a time and seeing the countdown feels choppy. The
causes are structural, not tunable with different spring values:

1. **The menu bar snaps its width.** `StatusRootView` reports every layout
   width through `onGeometryChange` and `StatusItemController.widthChanged`
   sets `NSStatusItem.length` from it. Each of the three staggered pills,
   every typed digit (the pill grows to fit, and the font weight and padding
   change), the error label and the collapse each change the layout. Because
   the change of `model.phase` and `visiblePills` happens inside
   `withAnimation`, SwiftUI interpolates the HStack width, so the callback
   fires on every animation frame and the bar re-lays out at display cadence.
   macOS cannot animate a status item's width: the neighbouring items jump
   while the pills animate inside a box that just snapped.
2. **The front app loses focus twice per entry.** `installMonitors()` puts up
   the `KeyCatcherPanel` and calls `NSApp.activate(ignoringOtherApps: true)`;
   `restorePreviousApp()` re-activates the previous app on collapse. The
   user's window title bar dims and its selection greys on open and comes
   back on close.
3. **The countdown waits on the start.** After Enter the pills retract into
   "Starting…" while the recovery agent is armed and `sudo pmset` runs, then
   the countdown pops in.

## Design

### 1. Fixed pill slots, one relayout per open and one per close

- Each pill occupies a slot whose width is that of its placeholder text
  ("Days", "Hours", "Minutes") at the typed weight plus the typed padding, so
  no digit, weight or padding change can alter the slot. Implemented by
  laying the placeholder out invisibly behind the visible text (a hidden
  `Text` in a `ZStack`), not by hard-coded widths. The visible text is
  centred in the slot.
- While `phase.isEntering`, all three slots are in the layout from the first
  frame. `visiblePills` no longer inserts and removes views; it drives each
  slot's content between hidden (scale 0.55 from leading, opacity 0) and
  shown (scale 1, opacity 1) with the existing stagger. `scaleEffect` and
  `opacity` do not affect layout, so the bar width does not move while the
  pills spring in or retract.
- Layout-changing state (`model.phase`) is set **outside** any animation
  transaction, so the bar snaps once to its final width. Content-only state
  (`visiblePills`, `focusVisible`, `focused`, `input`) keeps the springs.
- Order of operations:
  - Open: `phase = .entering` (bar widens once) → stagger the slots in.
  - Close: stagger the slots out → when the last slot has retracted
    (`stagePills` completion), `phase = .idle | .running` (bar shrinks once)
    → the countdown, if any, appears with its existing scale-from-leading
    transition.
  - Enter: slots retract → `phase = .starting` (bar snaps to countdown
    width) → projected countdown appears.
- The `matchedGeometryEffect` morph between the hours pill and the countdown
  is removed: it only ever animated across the per-frame width interpolation
  that is the jank. The countdown's own transition
  (`.scale(scale: 0.7, anchor: .leading).combined(with: .opacity)`) remains.
- `widthChanged` stays unanimated and keeps its rounding and `lastWidth`
  guard. With the above it is expected to fire on: open, close, session
  confirmation (hold ring appears), countdown shape change, error label
  appearing. A debug counter is not required; the fitting-size test below
  pins the invariant.

### 2. Non-activating key window

- `KeyCatcherPanel` gains `.nonactivatingPanel` in its style mask. A
  non-activating panel becomes key without activating the app, so key events
  reach the local key monitor while the user's app stays active and its
  windows keep focus.
- `installMonitors()` no longer calls `NSApp.activate`. `restorePreviousApp()`
  and `previousApp` are deleted along with their call sites (`collapse`,
  `run`, `reopenAfterFailure`, `expand`).
- `removeMonitors()` keeps `orderOut` of the panel, which returns key status
  to whatever had it.
- Settings window opening is unchanged: it activates the app explicitly
  through its own path.

### 3. Projected countdown on start

- On Enter in start mode, `run(mode: .start, …)` sets `model.pendingCountdown`
  to the countdown text of `SessionMath.newSession(now:duration:maxDuration:)`
  (remaining at `now`, in that session's `countdownShape`), exactly as extend
  already projects. Phase stays `.starting`, so no hold-to-end ring is drawn.
- `StatusRootView.starting` shows `countdownText` (which already falls back to
  `pendingCountdown`) in the running countdown's style, with accessibility
  label "Starting session". `MenuBarModel.startingText` is used only when
  `pendingCountdown` is nil (a start with no projection; should not happen
  but keeps the view total).
- Confirmation: `managerChanged` flips `.starting → .running`; the hold ring
  appears with its transition; the live `manager.countdownText` replaces the
  projection (same shape, so the text differs by at most the seconds that
  passed).
- Refusal: unchanged, `reopenAfterFailure(mode: .start)` restores the pills
  with the value and the error.

### 4. Everything else unchanged

Springs, stagger timing, the focus ring, the reject shake, the icon bounce,
the countdown tick, the hold-to-end ring, the right-click menu, Reduce Motion
handling, `Motion` values.

## Testing

- `UIStatusTests`: the hosting view's `fittingSize.width` while entering is
  identical for an empty input and for input `days 12, hours 3, minutes 45`,
  and identical for `visiblePills` 0 and 3 (slots are layout-stable).
- `UIStatusTests`: `KeyCatcherPanel().styleMask.contains(.nonactivatingPanel)`.
- A pure helper (on `MenuBarModel` or `SessionMath`) that computes the
  projected start countdown text is unit-tested for a 90-minute start
  ("1:30:00") and a 2-day start (days shape).
- Existing tests keep passing (`swift test`).
- Live check by the owner after install: open, type 1h30m, Enter, hold to
  end. The bar width changes once on open, once on Enter, once on close;
  the front app never loses focus; the countdown is visible the moment Enter
  is pressed.

## Out of scope

Animated status item width (the version that stuttered), moving entry into a
floating panel (direction A, declined), the lid-close brightness restore
(tracked separately).
