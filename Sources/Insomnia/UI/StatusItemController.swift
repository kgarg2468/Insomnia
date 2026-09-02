import AppKit
import SwiftUI

/// Owns the NSStatusItem and drives every state change of the menu bar UI.
///
/// The status bar button hosts a SwiftUI view; the item's width follows the
/// SwiftUI layout frame by frame so neighbours slide instead of jumping.
/// Keyboard input never reaches a text field inside a status bar window, so
/// a local key monitor routes digits / Tab / Enter / Esc / Delete to the
/// focused pill while the pills are open.
@MainActor
final class StatusItemController {
    let manager: SessionManager
    let status: any StatusSource
    let model = MenuBarModel()
    let reminder = ReminderScheduler()

    private let statusItem: NSStatusItem
    private var hostingView: NSHostingView<StatusRootView>?
    private var presetPopover: NSPopover?
    private var sessionPopover: NSPopover?

    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    /// Whoever was frontmost before we activated for typing; reactivated on collapse.
    private var previousApp: NSRunningApplication?
    /// Invalidates in-flight stagger steps when expand/collapse interleave.
    private var stageGeneration = 0
    private var lastWidth: CGFloat = 0
    private var widthTarget: CGFloat = 0
    private var widthStart: CGFloat = 0
    private var widthStartedAt: TimeInterval = 0
    private var widthTimer: Timer?

    init(manager: SessionManager, status: any StatusSource) {
        self.manager = manager
        self.status = status
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = [.terminationOnRemoval]
        installHostingView()
        observeManager()
    }

    // MARK: Status item

    private func installHostingView() {
        guard let button = statusItem.button else { return }
        let root = StatusRootView(
            model: model,
            manager: manager,
            onTapIcon: { [weak self] in self?.iconTapped() },
            onTapPill: { [weak self] field in self?.focus(field) },
            onTapCountdown: { [weak self] in self?.toggleSessionPopover() },
            onWidthChange: { [weak self] w in self?.widthChanged(w) }
        )
        let host = Self.makeHostingView(root)
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
    static func makeHostingView(_ root: StatusRootView) -> NSHostingView<StatusRootView> {
        let host = NSHostingView(rootView: root)
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

    private func widthChanged(_ width: CGFloat) {
        let w = max(width.rounded(.up), 24)
        guard w != widthTarget else { return }
        widthTarget = w
        if lastWidth == 0 || reduceMotion {
            widthTimer?.invalidate()
            widthTimer = nil
            lastWidth = w
            statusItem.length = w
            return
        }

        widthStart = statusItem.length
        widthStartedAt = Date.timeIntervalSinceReferenceDate
        widthTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickWidth() }
        }
        widthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        tickWidth()
    }

    private func tickWidth() {
        guard let timer = widthTimer else { return }
        let elapsed = Date.timeIntervalSinceReferenceDate - widthStartedAt
        if elapsed >= Motion.widthSettleDuration {
            statusItem.length = widthTarget
            lastWidth = widthTarget
            timer.invalidate()
            widthTimer = nil
            return
        }
        let progress = Motion.springProgress(elapsed: elapsed)
        let width = max(widthStart + (widthTarget - widthStart) * progress, 24)
        lastWidth = width
        statusItem.length = width
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
        switch (manager.isActive, model.phase) {
        case (true, .idle):
            withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                model.pendingCountdown = nil
                model.phase = .running
            }
        case (false, .running):
            closeSessionPopover()
            withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                model.pendingCountdown = nil
                model.phase = .idle
            }
        case (false, .entering(.extend)):
            // The session ended under the extend pills: they now start a new one.
            model.phase = .entering(.start)
            refreshPresetPopover()
        default:
            break
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
            toggleSessionPopover()
        }
    }

    // MARK: Expand / collapse

    func expand(mode: MenuBarModel.Mode) {
        closeSessionPopover()
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
        showPresetPopover(mode: mode)
    }

    /// Collapse to idle, or back to the countdown when extending.
    func collapse() {
        guard case let .entering(mode) = model.phase else { return }
        removeMonitors()
        closePresetPopover()
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.focusVisible = false
        }
        let target: MenuBarModel.Phase = (mode == .extend && manager.isActive) ? .running : .idle
        stagePills(to: 0) { [weak self] in
            guard let self else { return }
            withAnimation(Motion.base(reduceMotion: self.reduceMotion)) {
                self.model.phase = target
            }
        }
        restorePreviousApp()
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
        refreshPresetPopover()
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

    /// Enter: start or extend with the typed value, or shake when invalid.
    func commit() {
        guard case let .entering(mode) = model.phase else { return }
        guard let total = model.input.total else {
            model.rejectBounce += 1
            return
        }
        run(mode: mode, duration: total)
    }

    /// A preset chip: numbers animate into the pills, then the session starts.
    private func pickPreset(_ seconds: TimeInterval) {
        guard case let .entering(mode) = model.phase else { return }
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.input = DurationInput.from(seconds: seconds)
            model.focusVisible = false
        }
        let generation = stageGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.15 : 0.32)) { [weak self] in
            guard let self, self.stageGeneration == generation, self.model.phase == .entering(mode) else { return }
            self.run(mode: mode, duration: seconds)
        }
    }

    private func run(mode: MenuBarModel.Mode, duration: TimeInterval) {
        removeMonitors()
        closePresetPopover()
        stageGeneration += 1
        let expected: TimeInterval
        if mode == .extend, let s = manager.session {
            expected = s.remaining(at: Date()) + duration
        } else {
            expected = duration
        }
        // Morph now; the manager catches up (pmset takes a moment).
        model.pendingCountdown = SessionMath.formatRemaining(SessionMath.clamp(expected, maxDuration: manager.config.maxDuration))
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
                // Start failed: bring the pills back with the value intact and the error visible.
                reopenAfterFailure(mode: .start)
            } else if mode == .extend, manager.lastError != nil {
                showSessionPopover()
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
        showPresetPopover(mode: mode)
    }

    // MARK: Session actions (popover)

    private func extend(by seconds: TimeInterval) {
        Task { @MainActor in
            await manager.extend(by: seconds)
            refreshSessionPopover()
        }
    }

    private func endNow() {
        closeSessionPopover()
        Task { @MainActor in
            await manager.end(reason: .user)
        }
    }

    private func customExtend() {
        closeSessionPopover()
        expand(mode: .extend)
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Preset popover

    private func showPresetPopover(mode: MenuBarModel.Mode) {
        guard let button else { return }
        let popover = presetPopover ?? {
            let p = NSPopover()
            p.behavior = .applicationDefined
            p.animates = !reduceMotion
            return p
        }()
        presetPopover = popover
        let controller = NSHostingController(rootView: presetContent(mode: mode))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func presetContent(mode: MenuBarModel.Mode) -> PresetPopoverView {
        PresetPopoverView(
            manager: manager,
            mode: mode,
            onPick: { [weak self] p in self?.pickPreset(p) },
            onSettings: { [weak self] in self?.openSettings() },
            onQuit: { [weak self] in self?.quit() }
        )
    }

    /// The content observes the manager and model already; this only exists
    /// so a mode change re-renders the header.
    private func refreshPresetPopover() {
        guard let popover = presetPopover, popover.isShown, let mode = model.mode,
              let controller = popover.contentViewController as? NSHostingController<PresetPopoverView> else { return }
        controller.rootView = presetContent(mode: mode)
    }

    private func closePresetPopover() {
        guard let popover = presetPopover, popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: Session popover

    private func toggleSessionPopover() {
        if let p = sessionPopover, p.isShown {
            closeSessionPopover()
        } else {
            showSessionPopover()
        }
    }

    private func showSessionPopover() {
        guard let button else { return }
        status.refreshOnDemand()
        let popover = sessionPopover ?? {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = !reduceMotion
            return p
        }()
        sessionPopover = popover
        let controller = NSHostingController(rootView: sessionContent())
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func sessionContent() -> SessionPopoverView {
        SessionPopoverView(
            manager: manager,
            status: status,
            watts: status.instantWatts(),
            onExtend: { [weak self] s in self?.extend(by: s) },
            onCustomExtend: { [weak self] in self?.customExtend() },
            onEnd: { [weak self] in self?.endNow() },
            onSettings: { [weak self] in self?.openSettings() },
            onQuit: { [weak self] in self?.quit() }
        )
    }

    private func refreshSessionPopover() {
        guard let popover = sessionPopover, popover.isShown,
              let controller = popover.contentViewController as? NSHostingController<SessionPopoverView> else { return }
        controller.rootView = sessionContent()
    }

    private func closeSessionPopover() {
        guard let popover = sessionPopover, popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: Settings

    private func openSettings() {
        closePresetPopover()
        closeSessionPopover()
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

    /// A click anywhere in this app that is not the status item or the
    /// preset popover collapses the pills.
    private func handleLocalMouse(window: NSWindow?) {
        guard model.phase.isEntering else { return }
        let ours: [NSWindow?] = [button?.window, presetPopover?.contentViewController?.view.window]
        if let w = window, ours.contains(where: { $0 === w }) { return }
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
