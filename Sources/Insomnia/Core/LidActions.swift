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
        let config = manager.config

        if config.muteOnLidClose {
            muteSavingCurrent(manager)
        }

        let groups = freezer.plan(bundleIds: config.freezeList, config: config)
        for group in groups {
            freeze(group, docker: false, manager: manager)
        }

        let dockerGroup = await docker.idleDockerGroup(config: config)
        guard manager.isActive, !Task.isCancelled else { return }
        if let dockerGroup {
            freeze(dockerGroup, docker: true, manager: manager)
        }

        manager.pauseCountdown()
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
        let pids = group.pids.filter { !already.contains($0) }
        guard !pids.isEmpty else { return }
        do {
            try manager.journal { s in
                s.frozenPids.append(contentsOf: pids)
                if docker { s.dockerFrozen = true }
            }
        } catch {
            Log.error("could not journal freeze of \(group.bundleId): \(error.localizedDescription); left running")
            return
        }
        freezer.suspend(pids: pids, expectedParents: group.expectedParents)
        Log.info("froze \(group.name) (\(pids.count) pid(s))")
    }
}
