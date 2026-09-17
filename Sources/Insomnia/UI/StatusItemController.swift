import AppKit
import SwiftUI

/// Owns the NSStatusItem and drives every state change of the menu bar UI.
///
/// The status bar button hosts a SwiftUI view and the item's width is paced
/// to whatever that view fits into (`StatusWidthAnimator`); there is no
/// popover, so the status item is the whole interface apart from a
/// right-click NSMenu.
/// Keyboard input never reaches a text field inside a status bar window, so
/// a local key monitor routes digits / Tab / Enter / Esc / Delete to the
/// focused pill while the pills are open.
@MainActor
final class StatusItemController: NSObject {
    /// Builds the width animator over `apply` (which sets the item's length).
    /// The production one reads the button's screen; tests inject one whose
    /// display link they step by hand.
    typealias WidthAnimatorFactory = @MainActor (_ apply: @escaping (CGFloat) -> Void) -> StatusWidthAnimator

    let manager: SessionManager
    let status: any StatusSource
    let model = MenuBarModel()
    let reminder = ReminderScheduler()
    /// Opens the settings window. Injected because the window is owned by the
    /// app delegate, which outlives any one status item.
    private let showSettings: () -> Void
    private let makeWidthAnimator: WidthAnimatorFactory?

    private let statusItem: NSStatusItem
    private var hostingView: StatusHostingView?
    private var widthAnimator: StatusWidthAnimator?

    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    /// Holds keyboard focus while the pills are open; see `KeyCatcherPanel`.
    private var keyCatcher: KeyCatcherPanel?
    /// 1 Hz redraw of the projected countdown while a start is pending, so
    /// it does not sit frozen for the seconds the recovery agent and pmset
    /// take and then jump on confirmation.
    private var pendingTick: Timer?
    var pendingTickArmed: Bool { pendingTick != nil }
    /// DIAG: main-queue stall detector, alive for the controller's lifetime.
    private var watchdog: MainThreadWatchdog?

    /// Invalidates in-flight stagger steps when expand/collapse interleave.
    private var stageGeneration = 0
    /// Identifies the run whose completion is allowed to touch the UI. The
    /// manager answers in order, so an older completion can land while a
    /// newer run is still pending (extend, then extend again through the
    /// countdown); it must not clear what the newer one is showing.
    private var startGeneration = 0
    /// A paced close in flight: the slots stay while the pills fade and the
    /// bar wipes over them towards `landing()`'s layout, read when it lands
    /// (the session can end, or be confirmed, meanwhile). `generation` is
    /// the `stageGeneration` it began under; a reopen or a refusal bumps it,
    /// which drops the landing.
    private struct PacedClose {
        let generation: Int
        let landing: @MainActor () -> MenuBarModel.Phase
        /// When the pills started fading: the slots may not leave before
        /// `Motion.closeFadeDuration` has passed, however soon the bar lands.
        let fadeStartedAt: Date
    }

    private var pacedClose: PacedClose?
    /// The slots leaving once the fade has run out, when the bar landed
    /// first. Cancelled by anything that drops or re-aims the close.
    private var scheduledSlotRemoval: DispatchWorkItem?
    /// The width the layout last reported. During a paced close the bar
    /// heads for the landing width instead (`widthWithoutSlots`) and the
    /// report is only recorded, so a reopen can put the target back to it.
    private var layoutWidth: CGFloat = 0
    /// The width the status item is heading for.
    private(set) var widthTarget: CGFloat = 0
    /// How many times the width target has changed. The layout is meant to
    /// change once per open and once per close; tests pin that.
    private(set) var widthTargetChangeCount = 0
    /// The width the hosting view is laid out at (the widest content it has held).
    var hostWidth: CGFloat { hostingView?.frame.width ?? 0 }

    /// Autosave name so macOS remembers where the user drags the item.
    static let autosaveName = "insomnia.status"

    init(
        manager: SessionManager,
        status: any StatusSource,
        showSettings: @escaping () -> Void,
        makeWidthAnimator: WidthAnimatorFactory? = nil
    ) {
        self.manager = manager
        self.status = status
        self.showSettings = showSettings
        self.makeWidthAnimator = makeWidthAnimator
        Self.seedPreferredPositionIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = [.terminationOnRemoval]
        super.init()
        watchdog = MainThreadWatchdog() // DIAG
        Diag.log("watchdog started; button action none (SwiftUI onTapGesture), sendAction mask not set") // DIAG
        installHostingView()
        observeManager()
    }

    // MARK: Status item

    /// New status items are appended at the left of the existing group. On a
    /// crowded menu bar (notch Macs) that lands in the hidden overflow, so the
    /// item exists but is never seen. Seed a position near the right end the
    /// first time only; after that macOS keeps whatever the user drags to.
    static func seedPreferredPositionIfNeeded(defaults: UserDefaults = .standard) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(40, forKey: key)
    }

    private func installHostingView() {
        guard let button = statusItem.button else { return }
        let apply: (CGFloat) -> Void = { [statusItem] width in statusItem.length = width }
        widthAnimator = makeWidthAnimator?(apply) ?? StatusWidthAnimator(
            backingScale: { [weak button] in button?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 },
            maximumFramesPerSecond: { [weak button] in (button?.window?.screen ?? NSScreen.main)?.maximumFramesPerSecond },
            reduceMotion: { Motion.reduceMotion },
            makeLink: { [weak button] target, selector in
                (button?.window?.screen ?? NSScreen.main)?.displayLink(target: target, selector: selector)
            },
            apply: apply
        )
        let root = StatusRootView(
            model: model,
            manager: manager,
            onTapIcon: { [weak self] in self?.iconTapped() },
            onTapPill: { [weak self] field in self?.focus(field) },
            onTapCountdown: { [weak self] in self?.customExtend() },
            onHoldEnd: { [weak self] in self?.holdToEnd() },
            onWidthChange: { [weak self] w in self?.widthChanged(w) }
        )
        let host = Self.makeHostingView(root)
        host.onRightMouseDown = { [weak self] in self?.showMenu() }
        host.translatesAutoresizingMaskIntoConstraints = true
        // The height follows the button; the width is set from the layout
        // (`retargetWidth`) and never from the button, whose width is the
        // animated length: the content is laid out once at its own width,
        // anchored at the leading edge, and the item's window reveals or
        // clips it as the length moves.
        host.autoresizingMask = [.height]
        host.frame = NSRect(x: 0, y: 0, width: 0, height: button.bounds.height)
        button.addSubview(host)
        button.title = ""
        button.image = nil
        // SwiftUI handles the clicks; the cell must not paint a highlight.
        (button.cell as? NSButtonCell)?.highlightsBy = []
        hostingView = host
        // The layout may already have reported through `onGeometryChange`
        // while the host was measured above, before `hostingView` was set,
        // in which case `retargetWidth` treats the fitting width as a
        // repeat and never grows the frame: size the host here.
        host.frame.size.width = max(widthTarget, host.fittingSize.width.rounded(.up), 24)
        widthChanged(host.fittingSize.width)
        logFrames("installed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logFrames("after 1s") }
    }

    /// Centralizes the AppKit/SwiftUI boundary so its sizing contract can be
    /// regression-tested independently of a live menu bar.
    static func makeHostingView(_ root: StatusRootView) -> StatusHostingView {
        let host = StatusHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }

    /// Where the item sits on screen; used to find it for screenshots.
    func logFrames(_ tag: String) {
        guard let button, let host = hostingView else { return }
        let win = button.window.map { NSStringFromRect($0.frame) } ?? "?"
        Log.info("status item \(tag): window \(win) button \(NSStringFromRect(button.frame)) host \(NSStringFromRect(host.frame)) fitting \(NSStringFromSize(host.fittingSize)) length \(statusItem.length)")
        if let window = button.window, let screen = window.screen {
            let safe = screen.safeAreaInsets
            Log.info("status item \(tag): visible \(window.isVisible) alpha \(window.alphaValue) occlusion \(window.occlusionState.rawValue) screen \(screen.localizedName) \(NSStringFromRect(screen.frame)) safe {\(safe.top),\(safe.left),\(safe.bottom),\(safe.right)} button hidden \(button.isHidden) alpha \(button.alphaValue) host hidden \(host.isHidden) alpha \(host.alphaValue)")
        }
    }

    /// The layout reported a new width: send the item to it.
    private func widthChanged(_ width: CGFloat) {
        layoutWidth = width
        // A paced close is already heading for the landing width, and the
        // slots are still in this layout (a cleared error label, or the
        // slots arriving under an immediate Enter): keep the report for a
        // reopen, but do not turn the bar back to it.
        guard pacedClose == nil else { return }
        retargetWidth(width)
    }

    /// Send the item's length to `width`: paced or one-write as the animator
    /// decides (one write under Reduce Motion). The host only ever grows: it
    /// is laid out at the widest content it has held, so content on its way
    /// out always has room to finish its transition while the length
    /// narrows over it.
    ///
    /// `completion` runs once the width has landed and replaces any pending
    /// one. Without a completion, a repeat of the current target is ignored
    /// outright, so the layout reporting a width the bar was already sent
    /// to (the slots leaving at a paced landing) neither counts as a change
    /// nor disturbs the landing that is pending.
    private func retargetWidth(_ width: CGFloat, completion: (() -> Void)? = nil) {
        let w = max(width.rounded(.up), 24)
        if w != widthTarget {
            widthTarget = w
            widthTargetChangeCount += 1
            if let host = hostingView, host.frame.width < w {
                host.frame.size.width = w
            }
        } else if completion == nil {
            return
        }
        guard let widthAnimator else {
            completion?()
            return
        }
        widthAnimator.setTarget(w, animated: !reduceMotion, completion: completion)
    }

    /// The width the layout will settle at once the slots have left,
    /// measured on a throwaway host over the same state. A paced close
    /// heads there while the pills are still fading, before the layout
    /// switches; the layout's own report then lands on the same target.
    private func widthWithoutSlots(phase: MenuBarModel.Phase) -> CGFloat {
        let probe = MenuBarModel()
        probe.phase = phase
        probe.slotsPresent = false
        probe.pendingCountdown = model.pendingCountdown
        probe.pendingProjection = model.pendingProjection
        let root = StatusRootView(
            model: probe,
            manager: manager,
            onTapIcon: {},
            onTapPill: { _ in },
            onTapCountdown: {},
            onHoldEnd: {},
            onWidthChange: { _ in }
        )
        return Self.makeHostingView(root).fittingSize.width
    }

    /// Take the pills away and land on `landing()`'s layout, read when the
    /// bar lands (paced) or the last pill has settled (one-write): the
    /// session can end, or a pending start be confirmed, in that window.
    private func retract(landing: @escaping @MainActor () -> MenuBarModel.Phase) {
        Diag.log("retract branch \(pacedClose != nil ? "reaim" : widthAnimator?.isPaced == true ? "paced" : "one-write") phase \(model.phase) visiblePills \(model.visiblePills) widthTarget \(widthTarget)") // DIAG
        if let inFlight = pacedClose {
            // A paced close is already in flight (Esc, then Settings or a
            // click away): re-aim it at the new landing rather than start a
            // one-write retract over it, whatever `isPaced` says now (the
            // animator latched the mode when the flight began). The fade
            // keeps its start, so the slots still wait out the whole fade
            // and no longer; the removal waiting on it belongs to the old
            // landing and goes; the fade writes below are no-ops.
            stageGeneration += 1
            scheduledSlotRemoval?.cancel()
            scheduledSlotRemoval = nil
            pacedClose = PacedClose(generation: stageGeneration, landing: landing, fadeStartedAt: inFlight.fadeStartedAt)
            withAnimation(.easeInOut(duration: Motion.closeFadeDuration)) {
                model.pillsFading = true
                model.visiblePills = 0
            }
            retargetLanding()
        } else if widthAnimator?.isPaced == true {
            // Paced: the slots stay put and the pills fade where they stand
            // (no scale); the bar wipes over them from the trailing edge
            // towards the landing width, measured now, and the slots leave
            // in one relayout when it lands.
            stageGeneration += 1
            scheduledSlotRemoval?.cancel()
            scheduledSlotRemoval = nil
            pacedClose = PacedClose(generation: stageGeneration, landing: landing, fadeStartedAt: Date())
            withAnimation(.easeInOut(duration: Motion.closeFadeDuration)) {
                model.pillsFading = true
                model.visiblePills = 0
            }
            retargetLanding()
        } else {
            // One-write: the pills retract with their stagger, the slots
            // leave once the last has settled, and the bar snaps when the
            // layout reports that, never before, so it does not cut across
            // retracting content.
            stagePills(to: 0) { [weak self] in
                guard let self else { return }
                // Outside any animation: the slots and the error label leave
                // and the phase changes in one relayout; the countdown, if
                // any, runs its own transition.
                self.model.slotsPresent = false
                self.model.startError = nil
                self.model.phase = landing()
            }
        }
    }

    /// Send the bar to the width the layout will have once the slots of the
    /// paced close in flight have left. Its completion takes them out; a
    /// session change during the close calls this again, since the landing
    /// layout may have changed shape (the completion moves with it).
    private func retargetLanding() {
        guard let close = pacedClose else { return }
        // A removal already waiting on the fade belongs to the old landing:
        // the new one decides again when it lands.
        scheduledSlotRemoval?.cancel()
        scheduledSlotRemoval = nil
        let measureStart = Diag.nowMs // DIAG
        let landingWidth = widthWithoutSlots(phase: close.landing())
        Diag.log(String(format: "widthWithoutSlots %.1f result %.2f", Diag.nowMs - measureStart, landingWidth)) // DIAG
        retargetWidth(landingWidth) { [weak self] in
            guard let self, self.stageGeneration == close.generation else { return }
            // The slots leave only when both the bar has landed and the
            // pills have had their whole fade: a short landing (a small
            // distance, or a re-aim at a width already landed on, where the
            // completion runs before this call returns) must not cut across
            // pills still visible.
            let remaining = Motion.closeFadeDuration - Date().timeIntervalSince(close.fadeStartedAt)
            guard remaining > 0 else {
                self.removeSlots(landing: close)
                return
            }
            let removal = DispatchWorkItem { [weak self] in
                guard let self, self.stageGeneration == close.generation else { return }
                self.scheduledSlotRemoval = nil
                self.removeSlots(landing: close)
            }
            self.scheduledSlotRemoval = removal
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: removal)
        }
    }

    /// The paced close lands: the slots and the error label leave and the
    /// phase lands in one relayout, outside any animation; the countdown, if
    /// any, runs its own transition. The layout then reports the width the
    /// bar is already at, so nothing more is written. `pacedClose` clears
    /// here and not before, so that report is not turned into a target.
    private func removeSlots(landing close: PacedClose) {
        Diag.log("removeSlots generation \(close.generation) fadeAge \(String(format: "%.0f", Date().timeIntervalSince(close.fadeStartedAt) * 1000)) phase \(model.phase)") // DIAG
        pacedClose = nil
        model.pillsFading = false
        model.slotsPresent = false
        model.startError = nil
        model.phase = close.landing()
    }

    private var button: NSStatusBarButton? { statusItem.button }

    private var reduceMotion: Bool { Motion.reduceMotion }

    // MARK: Manager observation

    /// Sessions can start or end without the UI (reconcile at launch, the
    /// deadline timer, the battery floor). Keep the phase and the reminder
    /// in step with the manager.
    private func observeManager() {
        withObservationTracking {
            _ = manager.session
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.managerChanged()
                self.observeManager()
            }
        }
    }

    private func managerChanged() {
        let before = model.phase // DIAG
        defer { Diag.log("managerChanged isActive \(manager.isActive) countdownEmpty \(manager.countdownText.isEmpty) phase \(before) -> \(model.phase) pacedClose \(pacedClose != nil)") } // DIAG
        reminder.sync(endsAt: manager.session?.endsAt)
        if let next = Self.phase(forActive: manager.isActive, phase: model.phase) {
            switch next {
            case .idle, .running:
                // Outside any animation: the phase changes the layout, whose
                // new width the status item then heads for. What comes and
                // goes with it (the countdown and the ring at an end, the
                // ring at a confirmation) runs its own transition.
                stopPendingTick()
                // The session can land a hop before its countdown text does;
                // the projection stays up until the live text is there to
                // replace it (the run's completion clears it otherwise).
                if !manager.countdownText.isEmpty {
                    model.pendingCountdown = nil
                    model.pendingProjection = nil
                }
                model.phase = next
            case .entering, .starting:
                // Only the mode of the open pills changes, so nothing to animate.
                model.phase = next
            }
        }
        // A paced close lands on the layout the session leaves behind, which
        // has just changed shape (a countdown gone, a ring arrived): head
        // for that one instead. "One target per close" holds only while
        // the destination is unchanged.
        retargetLanding()
    }

    /// The phase a manager-side change puts the UI in, or nil to leave it
    /// alone. Pure so the transitions can be checked without a status item.
    static func phase(forActive active: Bool, phase: MenuBarModel.Phase) -> MenuBarModel.Phase? {
        switch (active, phase) {
        case (true, .idle), (true, .starting):
            // A pending start is confirmed the moment the session lands. A
            // start that stays inactive is the controller's to report: the
            // manager does not change under a refusal.
            .running
        case (false, .running):
            .idle
        case (false, .entering(.extend)):
            // The session ended under the extend pills: they now start a new one.
            .entering(.start)
        case (true, .entering(.start)):
            // A session came up while the start pills were open (the user
            // reopened them before the start finished): they now extend it.
            .entering(.extend)
        default:
            nil
        }
    }

    // MARK: Clicks

    func iconTapped() {
        Diag.log("iconTapped phase \(model.phase) pacedClose \(pacedClose != nil) animating \(widthAnimator?.isAnimating ?? false) slotsPresent \(model.slotsPresent) visiblePills \(model.visiblePills) keyCatcher \(keyCatcher != nil) typed \(model.input.total != nil)") // DIAG
        model.iconBounce += 1
        switch model.phase {
        case .idle:
            expand(mode: .start)
        case let .entering(mode):
            if pacedClose != nil {
                // A paced close is in flight (Esc, a click away): the phase
                // is still `.entering` but the pills are fading and the key
                // catcher is gone, so there is nothing to commit and nothing
                // more to collapse. The click brings the pills back.
                expand(mode: mode)
            } else if model.input.total != nil {
                commit()
            } else {
                collapse()
            }
        case .starting:
            // Nothing to act on until the manager answers.
            break
        case .running:
            customExtend()
        }
    }

    // MARK: Expand / collapse

    func expand(mode: MenuBarModel.Mode) {
        Diag.log("expand mode \(mode) phase \(model.phase) reopening \(pacedClose != nil) layoutWidth \(layoutWidth) widthTarget \(widthTarget) animating \(widthAnimator?.isAnimating ?? false)") // DIAG
        model.input = DurationInput()
        model.focused = .hours
        model.focusVisible = false
        stopPendingTick()
        model.pendingCountdown = nil
        model.pendingProjection = nil
        model.startError = nil
        // Reopened under a paced close: its landing is dropped here and by
        // the generation bump below, and the bar turns back (the ramp
        // restarts, since the direction changes).
        let reopening = pacedClose != nil
        pacedClose = nil
        scheduledSlotRemoval?.cancel()
        scheduledSlotRemoval = nil
        // Layout first, outside any animation: the three slots arrive at once
        // and the status item starts widening. The content staggers in
        // meanwhile; a pill born beyond the revealed width is clipped until
        // the bar reaches it.
        model.phase = .entering(mode)
        model.slotsPresent = true
        // Reopened under a close that never took the slots out: the layout
        // will not report again, so head back for the width it reported.
        retargetWidth(layoutWidth)
        if reopening {
            // The pills faded where they stood: fade them back, no stagger.
            withAnimation(.easeInOut(duration: Motion.closeFadeDuration)) {
                model.visiblePills = DurationInput.Field.allCases.count
                model.pillsFading = false
            }
        }
        stagePills(to: DurationInput.Field.allCases.count)
        installMonitors()
    }

    /// Collapse to idle, or back to the countdown when a session is running.
    func collapse() {
        Diag.log("collapse phase \(model.phase) entering \(model.phase.isEntering) pacedClose \(pacedClose != nil) keyCatcher \(keyCatcher != nil)") // DIAG
        guard model.phase.isEntering else { return }
        removeMonitors()
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.focusVisible = false
        }
        // The session is read at landing, not now: the pills take a moment
        // to leave and the session can end (or a restored one can land) in
        // that window, which would make a target captured up front install
        // a countdown for a session that is already over.
        retract { [manager] in Self.collapseTarget(sessionActive: manager.isActive) }
    }

    /// Where the pills land when dismissed. A live session always goes back
    /// to its countdown, whichever mode the pills were opened in: start-mode
    /// pills can outlive the start they were typed into.
    static func collapseTarget(sessionActive: Bool) -> MenuBarModel.Phase {
        sessionActive ? .running : .idle
    }

    /// Step `visiblePills` towards `target`, one pill per `Motion.stagger`.
    private func stagePills(to target: Int, completion: (() -> Void)? = nil) {
        stageGeneration += 1
        let generation = stageGeneration
        let current = model.visiblePills
        let steps: [Int] = current < target ? Array((current + 1)...target) : Array((target..<current).reversed())
        guard !steps.isEmpty else {
            if target == 0 {
                // Already retracted, so a retract is settling (Esc, then a
                // click on the mark): the generation bump above just cancelled
                // its completion, and the last pill may still be fading. Wait
                // the settle out again rather than snap under it.
                let settle = Motion.retractSettle(reduceMotion: reduceMotion)
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                    guard let self, self.stageGeneration == generation else { return }
                    completion?()
                }
            } else {
                // Already shown (a reopen under a paced close faded the
                // pills back in): just breathe the focus glow in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.stageGeneration == generation else { return }
                    withAnimation(Motion.base(reduceMotion: self.reduceMotion)) {
                        self.model.focusVisible = true
                    }
                }
                completion?()
            }
            return
        }
        let count = steps.count
        for (i, value) in steps.enumerated() {
            let delay = Motion.staggerDelay(index: i, count: count, reversed: false, reduceMotion: reduceMotion)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.stageGeneration == generation else { return }
                withAnimation(Motion.base(reduceMotion: self.reduceMotion)) {
                    self.model.visiblePills = value
                }
                if i == count - 1 {
                    if target > 0 {
                        // Let the last pill land, then breathe the focus glow in.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                            guard let self, self.stageGeneration == generation else { return }
                            withAnimation(Motion.base(reduceMotion: self.reduceMotion)) {
                                self.model.focusVisible = true
                            }
                        }
                        completion?()
                    } else {
                        // The completion takes the slots out of the layout:
                        // wait for the last pill to have faded so nothing
                        // visible is removed (one-write mode only; a paced
                        // close never stages to zero).
                        let settle = Motion.retractSettle(reduceMotion: self.reduceMotion)
                        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                            guard let self, self.stageGeneration == generation else { return }
                            completion?()
                        }
                    }
                }
            }
        }
    }

    // MARK: Focus and typing

    func focus(_ field: DurationInput.Field) {
        guard model.phase.isEntering else { return }
        withAnimation(Motion.snappy(reduceMotion: reduceMotion)) {
            model.focused = field
            model.focusVisible = true
        }
        model.focusBounce += 1
    }

    private func typeDigit(_ digit: Int) {
        let field = model.focused
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            if model.input.append(digit: digit, to: field) {
                if !model.input.canAcceptDigit(in: field), field != .minutes {
                    focusAfterTyping(field.next)
                }
            } else {
                model.rejectBounce += 1
            }
        }
    }

    private func focusAfterTyping(_ field: DurationInput.Field) {
        model.focused = field
        model.focusBounce += 1
    }

    private func backspace() {
        let field = model.focused
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            if !model.input.backspace(field), field != .days {
                model.focused = field.previous
                model.focusBounce += 1
            }
        }
    }

    // MARK: Commit

    /// Enter: start or extend with the typed value. With nothing typed it
    /// starts the default preset; while extending it shakes instead.
    func commit() {
        Diag.log("commit phase \(model.phase) keyCatcher \(keyCatcher != nil) typed \(model.input.total.map { String($0) } ?? "nil") pacedClose \(pacedClose != nil)") // DIAG
        guard case let .entering(mode) = model.phase else { return }
        // Nothing to commit once the monitors are down: Enter has already
        // been pressed (or Esc), and the slots are retracting.
        guard keyCatcher != nil else { return }
        switch MenuBarModel.commitAction(mode: mode, typed: model.input.total, defaultPreset: manager.config.defaultPreset) {
        case let .run(duration):
            run(mode: mode, duration: duration)
        case .reject:
            model.rejectBounce += 1
        }
    }

    private func run(mode: MenuBarModel.Mode, duration: TimeInterval) {
        removeMonitors()
        startGeneration += 1
        let generation = startGeneration
        // Cleared now, not when the slots leave: the error goes with the
        // retry, not only with its success (UIStartupTests pins that). On a
        // retry after a refusal the bar therefore narrows by the label at
        // Enter and again when the slots leave.
        model.startError = nil
        let now = Date()
        if mode == .extend, let s = manager.session {
            // The session is live, so the countdown stays up. Project the
            // session so the countdown already has the final shape while the
            // manager catches up (pmset takes a moment).
            let projected = SessionMath.extended(s, by: duration, now: now, maxDuration: manager.config.maxDuration)
            model.pendingProjection = nil
            model.pendingCountdown = SessionMath.formatCountdown(remaining: projected.remaining(at: now), shape: projected.countdownShape)
        } else {
            // No session yet: the manager has to arm the recovery agent and
            // disable sleep first, and either can take seconds or refuse. Show
            // the countdown the session will read the moment it is confirmed,
            // ticking meanwhile; the phase stays pending, so nothing that acts
            // on a session (the end ring) is drawn until then.
            let projection = MenuBarModel.projectedStart(now: now, duration: duration, maxDuration: manager.config.maxDuration)
            model.pendingProjection = projection
            model.pendingCountdown = projection.countdown(at: now)
        }
        // The phase flips now, outside any animation, so nothing can act on
        // the pills again while they leave (and the eye starts opening);
        // the slots stay in the layout until the bar has landed on the
        // countdown's width (paced) or the last pill has gone (one-write),
        // then leave in one relayout and the countdown scales in. Enter
        // while the bar is still opening just retargets it from where it is.
        model.phase = mode == .extend && manager.isActive ? .running : .starting
        if model.phase == .starting { armPendingTick() } else { stopPendingTick() }
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.focusVisible = false
        }
        retract { [model] in model.phase }

        Task { @MainActor in
            switch mode {
            case .start: await manager.start(duration: duration)
            case .extend: await manager.extend(by: duration)
            }
            guard generation == startGeneration else { return }
            stopPendingTick()
            model.pendingCountdown = nil
            model.pendingProjection = nil
            if manager.isActive {
                // Normally `managerChanged` has already done this; a session
                // that was live before the start (extend, or a start refused
                // as "already active") never changes and never fires it.
                if model.phase == .starting {
                    model.phase = .running
                }
                // Nor, then, does it re-aim a paced close still in flight:
                // the projection just cleared changes the landing layout's
                // shape, so head for what it leaves behind.
                retargetLanding()
            } else if model.phase == .starting {
                // Start refused: bring the pills back with the value intact
                // and say so. The full reason is in the right-click menu.
                reopenAfterFailure(mode: .start)
            } else {
                retargetLanding()
            }
        }
    }

    /// Put the pills straight back, all at once. No stagger: the refusal can
    /// arrive within the same frame the pills were retracting in, and
    /// replaying the open sequence on top of that half-finished retract is
    /// the churn the user sees as flicker. One animated retarget instead.
    private func reopenAfterFailure(mode: MenuBarModel.Mode) {
        Diag.log("reopenAfterFailure mode \(mode) phase \(model.phase) pacedClose \(pacedClose != nil) slotsPresent \(model.slotsPresent) layoutWidth \(layoutWidth) widthTarget \(widthTarget)") // DIAG
        let keep = model.input
        // Cancels a paced close still in flight: its landing and any
        // stagger work are dropped by the generation.
        stageGeneration += 1
        pacedClose = nil
        scheduledSlotRemoval?.cancel()
        scheduledSlotRemoval = nil
        // Layout outside any animation (one relayout, whether the slots were
        // still there or already gone), then the content springs back.
        model.phase = .entering(mode)
        model.slotsPresent = true
        model.startError = MenuBarModel.startFailedText
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.input = keep
            model.visiblePills = DurationInput.Field.allCases.count
            model.pillsFading = false
            model.focusVisible = true
        }
        // A paced close was wiping the bar over the pills: turn it back to
        // their width now; the layout reports the label's extra on top. A
        // no-op when the slots had already left, since the layout reports.
        retargetWidth(layoutWidth)
        installMonitors()
    }

    // MARK: Projected countdown

    /// 1 Hz redraw of the projected countdown, aligned to whole wall-clock
    /// seconds like the manager's live one. Runs only while the phase is
    /// `.starting`; stopped on confirmation, refusal or reopening.
    private func armPendingTick() {
        stopPendingTick()
        let first = SessionMath.nextSecondBoundary(after: Date())
        let timer = Timer(fire: first, interval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPendingCountdown() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pendingTick = timer
    }

    private func stopPendingTick() {
        pendingTick?.invalidate()
        pendingTick = nil
    }

    private func refreshPendingCountdown() {
        guard model.phase == .starting, let projection = model.pendingProjection else {
            stopPendingTick()
            return
        }
        model.pendingCountdown = projection.countdown(at: Date())
    }

    // MARK: Session actions

    private func endNow() {
        Task { @MainActor in
            await manager.end(reason: .user)
        }
    }

    /// The status item's hold-to-end ring completed. Ignored while a start is
    /// still in flight.
    func holdToEnd() {
        guard manager.isActive else { return }
        endNow()
    }

    /// Clicking the mark or the countdown while a session runs: reopen the
    /// pills, this time to extend. Ignored while a start is still in flight.
    func customExtend() {
        guard manager.isActive else { return }
        expand(mode: .extend)
    }

    // MARK: Right-click menu

    /// Right-click (or ctrl-click) on the status item. Not assigned to
    /// `statusItem.menu`, which would swallow the left click the pills need.
    private func showMenu() {
        guard let button else { return }
        // The lid, the battery and the watts are read right here, so the menu
        // opens on what the machine is doing now. The SSID and the throttled
        // browser list are whatever the last scan found: both have to be
        // awaited, and an open NSMenu blocks the main actor, so there is no
        // moment at which they could be filled into a menu that is already up.
        // Kick that scan off anyway, for the next opening.
        status.refreshInstant()
        status.refreshOnDemand()
        let menu = StatusMenu.menu(
            menuItems(),
            target: self,
            settings: #selector(menuOpenSettings),
            quit: #selector(menuQuit),
            relaunchBrowser: #selector(menuRelaunchBrowser(_:))
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func menuItems() -> [StatusMenu.Item] {
        StatusMenu.items(
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs,
            machine: StatusLines.machine(
                lidClosed: status.lidClosed,
                watts: status.instantWatts(),
                wifiSSID: WiFiStatusName.display(
                    ssid: status.wifiSSID,
                    locationAuthorized: (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
                ),
                batteryPercent: status.batteryPercent,
                isCharging: status.isCharging
            ),
            actions: StatusLines.actions(
                frozenCount: status.frozenCount,
                dockerPaused: status.dockerPaused,
                lastGap: status.lastGap
            ),
            throttledBrowsers: status.throttledBrowsers,
            error: manager.lastError
        )
    }

    @objc private func menuRelaunchBrowser(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        status.relaunchUnthrottled(name)
    }

    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func menuOpenSettings() {
        openSettings()
        showSettings()
    }

    // MARK: Settings

    private func openSettings() {
        if model.phase.isEntering {
            removeMonitors()
            withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                model.focusVisible = false
            }
            retract { [manager] in Self.collapseTarget(sessionActive: manager.isActive) }
        }
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
        // The key monitor below is local, so it only fires on events routed
        // to a key window this app owns, which an accessory app with no
        // window never has. The catcher panel is non-activating: making it
        // key moves key status to it without activating this app, so the
        // app in front stays frontmost and its windows keep their focus.
        let panel = KeyCatcherPanel()
        if let button { panel.move(toStatusButton: button) }
        panel.makeKeyAndOrderFront(nil)
        keyCatcher = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors always run on the main thread.
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleLocalMouse(window: event.window)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            Diag.log("globalMouse type \(event.type.rawValue) flags \(event.modifierFlags.rawValue)") // DIAG
            Task { @MainActor in self?.collapse() }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
        keyCatcher?.orderOut(nil)
        keyCatcher = nil
    }

    /// A click anywhere in this app that is not the status item collapses
    /// the pills.
    private func handleLocalMouse(window: NSWindow?) {
        let which = window == nil ? "nil" : window === button?.window ? "ours" : window === keyCatcher ? "catcher" : "other" // DIAG
        Diag.log("localMouse window \(which) phase \(model.phase)") // DIAG
        guard model.phase.isEntering else { return }
        // The catcher panel ignores the mouse so it should never be reported
        // here, but it is ours: it must not dismiss the pills either.
        if let w = window, w === button?.window || w === keyCatcher { return }
        collapse()
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.phase.isEntering else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        switch event.keyCode {
        case 53: // esc
            collapse()
            return true
        case 36, 76: // return, keypad enter
            commit()
            return true
        case 48: // tab
            focus(flags.contains(.shift) ? model.focused.previous : model.focused.next)
            return true
        case 51, 117: // delete, forward delete
            backspace()
            return true
        case 123: // left
            focus(model.focused.previous)
            return true
        case 124: // right
            focus(model.focused.next)
            return true
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1, let ch = chars.first else {
            return false
        }
        if let digit = ch.wholeNumberValue, ch.isASCII {
            typeDigit(digit)
            return true
        }
        switch ch.lowercased() {
        case "d": focus(.days); return true
        case "h": focus(.hours); return true
        case "m": focus(.minutes); return true
        default:
            // Swallow stray printable keys so nothing beeps while typing a time.
            return ch.isLetter || ch.isPunctuation || ch == " "
        }
    }
}

/// The SwiftUI host covers the status bar button, so the right click has to
/// be caught here rather than on the button. Ctrl-click is the same gesture
/// on a one-button mouse.
final class StatusHostingView: NSHostingView<StatusRootView> {
    var onRightMouseDown: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        Diag.log("rightMouseDown flags \(event.modifierFlags.rawValue) control \(event.modifierFlags.contains(.control)) clicks \(event.clickCount)") // DIAG
        onRightMouseDown?()
    }

    override func mouseDown(with event: NSEvent) {
        Diag.log("mouseDown flags \(event.modifierFlags.rawValue) control \(event.modifierFlags.contains(.control)) clicks \(event.clickCount)") // DIAG
        if event.modifierFlags.contains(.control) {
            onRightMouseDown?()
            return
        }
        super.mouseDown(with: event)
    }
}
