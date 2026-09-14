import Foundation

/// Spec section 4: the fixed, reversible action list run on lid close and
/// undone on lid open. Every step is journaled to state.json *before* the
/// side effect; undo reads state.json, never memory.
///
/// Order on close: mute (save volume + mute state first), freeze list (one
/// journal write per app), Docker rule, stop the countdown redraw.
/// Order on open: the exact reverse, driven by `SessionManager.undoLidActions`.
@MainActor
final class LidActions {
    private weak var manager: SessionManager?
    private let freezer: any Freezing
    private let docker: DockerRule
    private let audio: any AudioControlling

    init(manager: SessionManager, freezer: any Freezing, docker: DockerRule, audio: any AudioControlling) {
        self.manager = manager
        self.freezer = freezer
        self.docker = docker
        self.audio = audio
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
        do {
            try manager.journal { s in
                s.frozenProcesses.append(contentsOf: candidates)
                if docker { s.dockerFrozen = true }
            }
        } catch {
            Log.error("could not journal freeze of \(group.bundleId): \(error.localizedDescription); left running")
            return
        }
        let report = freezer.suspend(candidates, expectedParents: group.expectedParents)
        if !report.skipped.isEmpty {
            // Journal-first recorded every candidate. Whatever the kernel
            // would not let us stop (already stopped, gone, reparented,
            // reused) is not ours to resume, so it leaves the journal now.
            let skipped = Set(report.skipped)
            do {
                try manager.journal { s in
                    s.frozenProcesses.removeAll { skipped.contains($0.pid) }
                    if docker, report.suspended.isEmpty { s.dockerFrozen = false }
                }
            } catch {
                Log.error("could not drop \(skipped.count) skipped pid(s) from the journal: \(error.localizedDescription)")
            }
        }
        Log.info("froze \(group.name) (\(report.suspended.count) pid(s), \(report.skipped.count) skipped)")
    }
}
