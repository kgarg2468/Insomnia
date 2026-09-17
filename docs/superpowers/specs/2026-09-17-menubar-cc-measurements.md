# Menu bar width animation: what Control Center does with per-frame length writes (2026-09-17)

Method. The real Insomnia status item (autosave position 40, between the AirPods/Wi-Fi items and a
third-party item) had its `NSStatusItem.length` driven by a display link along known curves
(temporary in-app driver, distributed-notification trigger). A separate process polled
`CGWindowListCopyWindowInfo` at ~2 ms and recorded every change to the bounds of the on-screen
menu-bar-extra windows (layer 25; all are owned by "Control Center", which hosts every app's item).
"step px" is the neighbour's x movement between consecutive Control Center relayouts.

Findings (120 Hz built-in display):

1. Our own display link is not the problem. During real opens/closes the app's animator logged
   mostly 8 ms frames, but with clusters of 30-46 ms gaps (main thread blocked in
   CA::Render::Context::wait_for_synchronize while the status window is resized each frame).
   A time-based spring turns such a gap into a 21-28 pt step in one write.

2. Control Center tracks writes of ~3 px per frame: linear 0.6 s @120 Hz (3 px/frame), 194 px:
   65 relayouts open, 53 close, steps 2-3 px with a handful of coalesced 5-9 px steps (two frames
   merged), no pause longer than ~25 ms, no deferred flush, last move within 10 ms of the last
   write. This was the highest write rate tested and the best-tracked, which argues against a
   pure "too many writes per second" (backpressure) explanation.

3. Larger steps trip a deferral: Control Center stops moving the neighbours and, ~0.5 s after the
   last accepted write, applies the whole remainder in one jump.
   - linear 0.25 s (7 px/frame): open tracked (36 moves) but ended with an 18 px catch-up; close
     froze after 7 moves (105 ms) and jumped 111 px at 614 ms.
   - linear 0.5 s @60 Hz (6.5 px/write): tracked 21 moves to 350 ms, then a 50 px jump at 857 ms
     (open) and 54 px at 854 ms (close).
   - spring 0.45/0.92 (the shipped animator; 15-17 px early steps, sub-pixel tail): open tracked
     to 415 ms then one last move at 947 ms; close showed 13-15 px coalesced steps.
   - easeout 0.4 s: open tracked, but 19 px of travel had not arrived 1.2 s later; close began
     with 29 and 40 px coalesced steps.
   - step (one write): the neighbours move once, 194 px, ~110 ms after the write.

4. Control Center's own animation when an item is inserted moves the neighbours 1-2 px per frame
   for about a second: ~3 px/frame is at the fast end of what the system itself does.

5. The user's 60 fps video of the shipped build matches (3): neighbours slide for ~200 ms, freeze,
   then cut to the final layout ("jumps into an animation and then cuts off").

What is established vs inferred. Established: (a) our own callbacks stall for 30-46 ms at times;
(b) the shipped spring turns those stalls into 20-28 pt writes; (c) writes of ~3 px per frame at
120 Hz were relayed frame by frame; (d) runs with 6-17 px writes ended in a pause of roughly
0.5 s followed by one large relayout, in 5 of 8 such runs. Inferred: that Control Center has a
step-size threshold and a ~0.5 s deferred flush. An alternative (render-server backpressure that
delays both our callbacks and Control Center's relayout) is not excluded by these runs alone,
though (c) being the highest write rate tested argues against it. The acceptance test for any
fix is therefore live and repeated: five opens and five closes with the probe, no neighbour step
above 4 px and no relayout later than two frames after the last write.

Conclusion. Never let a single write move the length by more than ~3 pt at 120 Hz, regardless of
elapsed time; pace by frames, not by the clock, so a stalled frame delays the animation by the
stall instead of producing a jump. Ease only at the tail. Keep the one-write layout (a single
neighbour jump) as the fallback where pacing is not verified (slower displays, Reduce Motion).
Raw runs: /tmp/cctest/p-*.txt (probe), app log lines "debug width ...".
