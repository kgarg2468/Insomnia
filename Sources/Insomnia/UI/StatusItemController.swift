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

    /// Whoever was frontmost before we activated for typing; reactivated on collapse.
    private var previousApp: NSRunningApplication?
    /// Invalidates in-flight stagger steps when expand/collapse interleave.
    private var stageGeneration = 0
    private var lastWidth: CGFloat = 0

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
            withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                model.pendingCountdown = nil
                model.phase = next
            }
        case .entering:
            // Only the mode of the open pills changes, so nothing to animate.
            model.phase = next
        }
    }

    /// The phase a manager-side change puts the UI in, or nil to leave it
    /// alone. Pure so the transitions can be checked without a status item.
    static func phase(forActive active: Bool, phase: MenuBarModel.Phase) -> MenuBarModel.Phase? {
        switch (active, phase) {
        case (true, .idle):
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

    private func iconTapped() {
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
        case .running:
            customExtend()
        }
    }

    // MARK: Expand / collapse

    func expand(mode: MenuBarModel.Mode) {
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)

        model.input = DurationInput()
        model.focused = .hours
        model.focusVisible = false
        model.pendingCountdown = nil
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.phase = .entering(mode)
        }
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
            withAnimation(Motion.base(reduceMotion: self.reduceMotion)) {
                self.model.phase = target
            }
        }
        restorePreviousApp()
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
            completion?()
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
                    }
                    completion?()
                }
            }
        }
    }

    private func restorePreviousApp() {
        guard NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.isKeyWindow && !($0 is NSPanel) }) else { return }
        if let prev = previousApp, prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate()
        } else {
            NSApp.deactivate()
        }
        previousApp = nil
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
        switch MenuBarModel.commitAction(mode: mode, typed: model.input.total, defaultPreset: manager.config.defaultPreset) {
        case let .run(duration):
            run(mode: mode, duration: duration)
        case .reject:
            model.rejectBounce += 1
        }
    }

    private func run(mode: MenuBarModel.Mode, duration: TimeInterval) {
        removeMonitors()
        stageGeneration += 1
        // Morph now; the manager catches up (pmset takes a moment). Project
        // the session so the placeholder already has the final shape.
        let now = Date()
        let projected: Session
        if mode == .extend, let s = manager.session {
            projected = SessionMath.extended(s, by: duration, now: now, maxDuration: manager.config.maxDuration)
        } else {
            projected = SessionMath.newSession(now: now, duration: duration, maxDuration: manager.config.maxDuration)
        }
        model.pendingCountdown = SessionMath.formatCountdown(remaining: projected.remaining(at: now), shape: projected.countdownShape)
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.focusVisible = false
            model.visiblePills = 0
            model.phase = .running
        }
        restorePreviousApp()

        Task { @MainActor in
            switch mode {
            case .start: await manager.start(duration: duration)
            case .extend: await manager.extend(by: duration)
            }
            model.pendingCountdown = nil
            if !manager.isActive {
                // Start failed: bring the pills back with the value intact.
                // The error itself shows up in the right-click menu.
                reopenAfterFailure(mode: .start)
            }
        }
    }

    private func reopenAfterFailure(mode: MenuBarModel.Mode) {
        let keep = model.input
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.phase = .entering(mode)
            model.input = keep
        }
        stagePills(to: DurationInput.Field.allCases.count)
        installMonitors()
    }

    // MARK: Session actions

    private func endNow() {
        Task { @MainActor in
            await manager.end(reason: .user)
        }
    }

    /// The status item's hold-to-end ring completed. Ignored while a start is
    /// still in flight.
    private func holdToEnd() {
        guard manager.isActive else { return }
        endNow()
    }

    /// Clicking the cup or the countdown while a session runs: reopen the
    /// pills, this time to extend. Ignored while a start is still in flight.
    private func customExtend() {
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
                withAnimation(Motion.base(reduceMotion: self.reduceMotion)) {
                    self.model.phase = self.manager.isActive ? .running : .idle
                }
            }
        }
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
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
    }

    /// A click anywhere in this app that is not the status item collapses
    /// the pills.
    private func handleLocalMouse(window: NSWindow?) {
        guard model.phase.isEntering else { return }
        if let w = window, w === button?.window { return }
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
