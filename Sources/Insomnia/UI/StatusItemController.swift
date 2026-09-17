import AppKit
import SwiftUI

/// Owns the NSStatusItem and drives every state change of the menu bar UI.
///
/// The status bar button hosts a SwiftUI view and the item's width is set to
/// whatever that view fits into; there is no popover, so the status item is
/// the whole interface apart from a right-click NSMenu.
/// Keyboard input never reaches a text field inside a status bar window, so
/// a local key monitor routes digits / Tab / Enter / Esc / Delete to the
/// focused pill while the pills are open.
@MainActor
final class StatusItemController: NSObject {
    let manager: SessionManager
    let status: any StatusSource
    let model = MenuBarModel()
    let reminder = ReminderScheduler()
    /// Opens the settings window. Injected because the window is owned by the
    /// app delegate, which outlives any one status item.
    private let showSettings: () -> Void

    private let statusItem: NSStatusItem
    private var hostingView: StatusHostingView?

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

    /// Invalidates in-flight stagger steps when expand/collapse interleave.
    private var stageGeneration = 0
    /// Identifies the run whose completion is allowed to touch the UI. The
    /// manager answers in order, so an older completion can land while a
    /// newer run is still pending (extend, then extend again through the
    /// countdown); it must not clear what the newer one is showing.
    private var startGeneration = 0
    private var lastWidth: CGFloat = 0
    /// How many times the status item's width has been set. The layout is
    /// meant to change once per open and once per close; tests pin that.
    private(set) var widthChangeCount = 0

    /// Autosave name so macOS remembers where the user drags the item.
    static let autosaveName = "insomnia.status"

    init(manager: SessionManager, status: any StatusSource, showSettings: @escaping () -> Void) {
        self.manager = manager
        self.status = status
        self.showSettings = showSettings
        Self.seedPreferredPositionIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = [.terminationOnRemoval]
        super.init()
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
        host.autoresizingMask = [.width, .height]
        host.frame = button.bounds
        button.addSubview(host)
        button.title = ""
        button.image = nil
        // SwiftUI handles the clicks; the cell must not paint a highlight.
        (button.cell as? NSButtonCell)?.highlightsBy = []
        hostingView = host
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

    /// Set the item's width to what SwiftUI just laid out. Deliberately not
    /// animated: every change of `NSStatusItem.length` forces a full menu bar
    /// relayout, so interpolating it at display cadence made the whole bar
    /// stutter. The content animates inside the new width instead.
    private func widthChanged(_ width: CGFloat) {
        let w = max(width.rounded(.up), 24)
        guard w != lastWidth else { return }
        lastWidth = w
        widthChangeCount += 1
        statusItem.length = w
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
        reminder.sync(endsAt: manager.session?.endsAt)
        guard let next = Self.phase(forActive: manager.isActive, phase: model.phase) else { return }
        switch next {
        case .idle, .running:
            // Outside any animation: the phase changes the layout, and the
            // status item's width has to snap once, not interpolate. The
            // hold-to-end ring that a confirmation adds still runs its own
            // transition off the phase change.
            stopPendingTick()
            // The session can land a hop before its countdown text does; the
            // projection stays up until the live text is there to replace it
            // (the run's completion clears it otherwise).
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
        model.iconBounce += 1
        switch model.phase {
        case .idle:
            expand(mode: .start)
        case .entering:
            if model.input.total != nil {
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
        model.input = DurationInput()
        model.focused = .hours
        model.focusVisible = false
        stopPendingTick()
        model.pendingCountdown = nil
        model.pendingProjection = nil
        model.startError = nil
        // Layout first, outside any animation: the three slots arrive at once
        // and the status item widens once. Then the content staggers in.
        model.phase = .entering(mode)
        model.slotsPresent = true
        stagePills(to: DurationInput.Field.allCases.count)
        installMonitors()
    }

    /// Collapse to idle, or back to the countdown when a session is running.
    func collapse() {
        guard model.phase.isEntering else { return }
        removeMonitors()
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.focusVisible = false
        }
        stagePills(to: 0) { [weak self] in
            guard let self else { return }
            // Read the session here, not before the stagger: the pills take a
            // moment to retract and the session can end (or a restored one can
            // land) in that window, which would make a target captured up
            // front install a countdown for a session that is already over.
            let target = Self.collapseTarget(sessionActive: self.manager.isActive)
            // Outside any animation: the slots and the error label leave and
            // the phase changes in one relayout, so the status item narrows
            // once; the countdown, if any, then runs its own transition.
            self.model.slotsPresent = false
            self.model.startError = nil
            self.model.phase = target
        }
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
                        // The completion snaps the bar to its next width, which
                        // clips whatever is still drawn: wait for the last pill
                        // to have faded before the layout changes under it.
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
        // the pills again while they retract; the slots stay in the layout
        // until the last one has gone, then leave in one relayout and the
        // countdown appears in the width the status item snapped to.
        model.phase = mode == .extend && manager.isActive ? .running : .starting
        if model.phase == .starting { armPendingTick() } else { stopPendingTick() }
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.focusVisible = false
        }
        stagePills(to: 0) { [weak self] in
            self?.model.slotsPresent = false
        }

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
            } else if model.phase == .starting {
                // Start refused: bring the pills back with the value intact
                // and say so. The full reason is in the right-click menu.
                reopenAfterFailure(mode: .start)
            }
        }
    }

    /// Put the pills straight back, all at once. No stagger: the refusal can
    /// arrive within the same frame the pills were retracting in, and
    /// replaying the open sequence on top of that half-finished retract is
    /// the churn the user sees as flicker. One animated retarget instead.
    private func reopenAfterFailure(mode: MenuBarModel.Mode) {
        let keep = model.input
        stageGeneration += 1
        // Layout outside any animation (one relayout, whether the slots were
        // still retracting or already gone), then the content springs back.
        model.phase = .entering(mode)
        model.slotsPresent = true
        model.startError = MenuBarModel.startFailedText
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.input = keep
            model.visiblePills = DurationInput.Field.allCases.count
            model.focusVisible = true
        }
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
            stagePills(to: 0) { [weak self] in
                guard let self else { return }
                self.model.slotsPresent = false
                self.model.phase = self.manager.isActive ? .running : .idle
            }
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
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
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
        onRightMouseDown?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightMouseDown?()
            return
        }
        super.mouseDown(with: event)
    }
}
