import Foundation

/// Spec section 4: the fixed, reversible action list run on lid close and
/// undone on lid open. Every step is journaled to state.json *before* the
/// side effect; undo reads state.json, never memory.
///
/// Order on close: darken (save display brightness and keyboard backlight
/// first, then set both to 0 and ask the display to sleep), mute (save
/// volume + mute state first), freeze list (one journal write per app),
/// Docker rule, stop the countdown redraw.
/// Order on open: the exact reverse, driven by `SessionManager.undoLidActions`.
@MainActor
final class LidActions {
    private weak var manager: SessionManager?
    private let freezer: any Freezing
    private let docker: DockerRule
    private let audio: any AudioControlling
    private let display: any DisplayDimming
    private let keyboard: any KeyboardBacklighting

    init(
        manager: SessionManager,
        freezer: any Freezing,
        docker: DockerRule,
        audio: any AudioControlling,
        display: any DisplayDimming = NoopDisplayDimmer(),
        keyboard: any KeyboardBacklighting = NoopKeyboardBacklight()
    ) {
        self.manager = manager
        self.freezer = freezer
        self.docker = docker
        self.audio = audio
        self.display = display
        self.keyboard = keyboard
    }

    func onClose() async {
        guard let manager, manager.isActive, !Task.isCancelled else {
            Log.info("lid closed: no session, nothing to do")
            return
        }
        // One lifecycle transaction: journal writes and SIGSTOPs happen
        // under the recovery lock, after any end already in flight.
        let ran = await manager.runExclusive("lid close") { [self, manager] in
            guard manager.isActive, !Task.isCancelled else { return }
            let ticket = manager.endTicket
            let config = manager.config

            if config.darkenDisplayOnLidClose {
                darkenSavingCurrent(manager)
            }

            if config.muteOnLidClose {
                muteSavingCurrent(manager)
            }

            let groups = freezer.plan(bundleIds: config.freezeList, config: config)
            for group in groups {
                freeze(group, docker: false, manager: manager)
            }

            let dockerGroup = await docker.idleDockerGroup(config: config)
            // An end requested while the probe ran wins: it is queued right
            // behind this transaction and must not find a fresh freeze.
            guard manager.isActive, manager.endTicket == ticket, !Task.isCancelled else { return }
            if let dockerGroup {
                freeze(dockerGroup, docker: true, manager: manager)
            }

            manager.pauseCountdown()
        }
        if !ran { Log.error("lid close actions skipped: recovery lock busy") }
    }

    func onOpen() async {
        guard let manager, manager.isActive, !Task.isCancelled else {
            Log.info("lid opened: no session, nothing to do")
            return
        }
        await manager.undoLidActions()
        guard manager.isActive, !Task.isCancelled else { return }
        manager.resumeCountdown()
    }

    // MARK: Private

    /// With `pmset disablesleep 1` macOS never turns the built-in panel or
    /// the keyboard backlight off on lid close, so this does. Brightness 0
    /// is the mechanism; the display sleep request is a bonus that macOS
    /// ignores while any process (an agent, say) holds a display assertion.
    private func darkenSavingCurrent(_ manager: SessionManager) {
        do {
            let current = try display.readBrightness()
            try manager.journal { s in
                // Keep an earlier save if a previous close was never undone.
                if s.savedDisplayBrightness == nil { s.savedDisplayBrightness = current }
            }
            do {
                try display.setBrightness(0)
                Log.info("display darkened (was brightness \(current))")
            } catch {
                // The journal entry stays: the open restores whatever is there.
                Log.error("display darken failed: \(error.localizedDescription)")
            }
        } catch {
            Log.error("display darken on lid close skipped: \(error.localizedDescription)")
        }

        do {
            if let current = try keyboard.readBrightness() {
                try manager.journal { s in
                    if s.savedKeyboardBrightness == nil { s.savedKeyboardBrightness = current }
                }
                do {
                    try keyboard.setBrightness(0)
                    Log.info("keyboard backlight off (was brightness \(current))")
                } catch {
                    Log.error("keyboard backlight off failed: \(error.localizedDescription)")
                }
            } else {
                Log.info("no built-in keyboard backlight; skipped")
            }
        } catch {
            Log.error("keyboard backlight on lid close skipped: \(error.localizedDescription)")
        }

        do {
            try display.requestSleep()
            Log.info("display sleep requested")
        } catch {
            Log.info("display sleep request failed: \(error.localizedDescription)")
        }
    }

    private func muteSavingCurrent(_ manager: SessionManager) {
        do {
            let current = try audio.read()
            try manager.journal { s in
                // Keep an earlier save if a previous close was never undone.
                if s.savedOutputVolume == nil { s.savedOutputVolume = current.volume }
                if s.savedMuted == nil { s.savedMuted = current.muted }
            }
            try audio.mute()
            Log.info("muted (was volume \(current.volume), muted \(current.muted))")
        } catch {
            Log.error("mute on lid close failed: \(error.localizedDescription)")
        }
    }

    private func freeze(_ group: FreezeGroup, docker: Bool, manager: SessionManager) {
        let already = Set(manager.state.frozenPids)
        var candidates: [FrozenProcess] = []
        for pid in group.pids where !already.contains(pid) {
            guard let identity = group.identities[pid] else {
                Log.error("freeze: no start identity for pid \(pid) of \(group.name); left running")
                continue
            }
            candidates.append(FrozenProcess(pid: pid, identity: identity))
        }
        guard !candidates.isEmpty else { return }
        let candidatePids = Set(candidates.map(\.pid))
        // Journal first, but without identity: an entry with no identity is
        // never resumed by the app or backstop.sh, so until the kernel has
        // said which pids it actually stopped the journal claims none of
        // them. Identity is added below only for the confirmed stops.
        let provisional = candidates.map { FrozenProcess(pid: $0.pid, identity: nil) }
        do {
            try manager.journal { s in
                s.frozenProcesses.append(contentsOf: provisional)
                if docker { s.dockerFrozen = true }
            }
        } catch {
            Log.error("could not journal freeze of \(group.bundleId): \(error.localizedDescription); left running")
            return
        }
        let report = freezer.suspend(candidates, expectedParents: group.expectedParents)
        // One write replaces the provisional entries: confirmed stops gain
        // their identity, skipped pids (already stopped, gone, reparented,
        // reused) leave. If this write fails the provisional entries stay
        // on disk, still without identity, so nothing later resumes them;
        // any that really are stopped are reported for manual recovery.
        let suspended = Set(report.suspended)
        let confirmed = candidates.filter { suspended.contains($0.pid) }
        do {
            try manager.journal { s in
                s.frozenProcesses.removeAll { candidatePids.contains($0.pid) }
                s.frozenProcesses.append(contentsOf: confirmed)
                if docker, confirmed.isEmpty { s.dockerFrozen = false }
            }
        } catch {
            Log.error("could not confirm freeze of \(group.bundleId) in the journal: \(error.localizedDescription); \(candidates.count) pid(s) stay journaled without identity and will not be resumed automatically")
        }
        Log.info("froze \(group.name) (\(report.suspended.count) pid(s), \(report.skipped.count) skipped)")
    }
}
