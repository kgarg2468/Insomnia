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
  reach the local key monitor while the user's app stays frontmost.
  Measured on 2026-09-17 with a throwaway observer app: the front app keeps
  its active state (no `didResignActive`, menu bar unchanged) and only its
  key-window highlight moves to the panel while the pills are open, exactly
  as with Spotlight. That handoff is unavoidable without Input Monitoring
  permission and is the native behaviour.
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

Moving entry into a floating panel (direction A, declined), the lid-close
brightness restore (tracked separately). Animating the status item's width
was out of scope for revision 1 (the earlier version that stuttered
interpolated the SwiftUI layout); revision 2 below animates it a different
way.

## Revision 2 (2026-09-17): animated width

### What the first revision looked like on screen

A 60 fps recording of the installed build showed the remaining jank was the
width itself, not the content: on click the item snapped to its full width
in one frame, so every neighbouring item teleported left and only then did
the pills stagger in; on Enter the pills faded, the bar snapped narrower and
the countdown and the ring appeared at full size in the same frame (the
`.animation(_:value:)` on the container never reached the branch switch);
and the eye's blink was over in about six frames.

### Measurement

Setting `NSStatusItem.length` from a `CADisplayLink` costs 0.5 ms mean and
3.6 ms worst case per call, and held 120 Hz for 241 consecutive frames. The
earlier stutter came from interpolating the SwiftUI layout (a relayout of
the hosting view plus a menu bar relayout per frame), not from the length
set itself. Driving the length alone, once per frame, is affordable.

### Model

- **The width is animated by a spring on the length, decoupled from
  layout.** `StatusWidthAnimator` runs a `CADisplayLink` that steps
  `WidthSpringMotion`, a pure closed-form evaluation of SwiftUI's `Spring`
  (`Motion.widthSpring`: response 0.45, damping ratio 0.86) from the moment
  of the last retarget, and sets `length` once per frame, rounded to the
  backing scale. A retarget mid-flight re-bases the spring on the current
  value and velocity, so Enter landing while the bar is still growing bends
  the curve without a jump. The link is invalidated the moment the spring
  is within 0.25 pt of the target with negligible velocity. Under Reduce
  Motion the length snaps as before.
- **The hosting view is never laid out per frame.** It no longer tracks the
  button's width. It is given an explicit frame at the layout's width,
  anchored at the leading edge, and only ever grows (the widest content it
  has held); the status item's window reveals or clips it as the length
  springs, so the content is laid out once per state change and the bar
  reads as growing out of the mark. Content on its way out keeps its place
  while the bar narrows over it.
- **The width target still comes from the layout**, once per state change
  (`widthTargetChangeCount`, pinned by the tests as before). What changed is
  that the layout's width is a target, not a set.
- **Transitions carry their own animation.** The countdown, the ring, the
  error label and a pill born shown use `AnyTransition.animation(_:)`
  (`Motion.countdownTransition` and friends), so they run in whatever
  transaction the branch switch lands in; the container's
  `.animation(_:value:)` is gone.

### Choreography

- Open: the width starts springing and the pills stagger in (40 ms) at once;
  a pill born beyond the revealed width is clipped until the bar reaches it.
- Enter: the pills retract as before and the eye starts opening immediately
  (it no longer waits for the confirmation; a refusal closes it again with
  the pills coming back). `Motion.narrowDelay` (0.1 s) into the retract the
  width retargets to the width of the layout the slots will leave behind,
  measured on a throwaway host over the same state, so the bar is already
  narrowing while the last pill fades and its edge never crosses a solid
  pill. The slots leave the layout when the last pill has faded (the 0.2 s
  settle, unchanged) and the countdown scales in from the leading edge; the
  layout's report then lands on the width already in flight.
- Escape / close: the same, landing on the idle mark or the countdown.
- End of session: the countdown and the ring scale out, the eye closes and
  the width springs back, all at once.
- Reduce Motion: the width snaps once the slots have left (no early narrow),
  everything else crossfades, as before.
- The eye's blink runs on `Motion.blink` (spring, response 0.7, damping
  fraction 0.9; `easeInOut` 0.3 s under Reduce Motion), about 0.6 s, so the
  lid lift and the lash hand-over are seen. The lash fade ramps are
  unchanged.

### Testing

- `WidthSpringMotion`: reaches its target and settles in finite steps
  without visible overshoot; a retarget mid-flight is continuous in value
  and velocity; the curve is a function of time (two half-steps equal one
  whole step).
- `widthTargetChangeCount`: once per open, once per close, as before; the
  early narrow lands on the same width the layout then reports.
- `Motion.blink` is slower than `Motion.base`.
- Live check by the owner: click, type, Enter, hold to end. The bar grows
  and narrows continuously with the pills, the countdown scales in, the
  neighbours never jump.
