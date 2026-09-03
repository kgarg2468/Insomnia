import Darwin
import Foundation

/// Sending signals to processes Insomnia froze. Tree discovery and the
/// denylist live in `Freezer`; this is only the signal layer.
protocol ProcessSignaling: Sendable {
    /// SIGSTOP each pid. Missing or foreign pids are ignored.
    func suspend(pids: [Int32], expectedParents: [Int32: Int32])
    /// SIGCONT each pid. Missing or foreign pids are ignored.
    func resume(pids: [Int32])
}

struct ProcessSignalState: Sendable, Equatable {
    let ppid: Int32
    let stopped: Bool
}

struct SignalProcessControl: ProcessSignaling {
    typealias StateLookup = @Sendable (Int32) -> ProcessSignalState?

    private let stateLookup: StateLookup

    init(stateLookup: @escaping StateLookup = SignalProcessControl.kernelState) {
        self.stateLookup = stateLookup
    }

    func suspend(pids: [Int32], expectedParents: [Int32: Int32]) {
        let eligible = Self.suspendable(pids: pids, expectedParents: expectedParents, stateLookup: stateLookup)
        let eligibleSet = Set(eligible)
        for pid in pids where pid > 0 && !eligibleSet.contains(pid) {
            Log.info("SIGSTOP \(pid) skipped: parent changed or process exited")
        }
        signal(eligible, SIGSTOP, "SIGSTOP")
    }

    func resume(pids: [Int32]) {
        let eligible = Self.resumable(pids: pids, stateLookup: stateLookup)
        let eligibleSet = Set(eligible)
        for pid in pids where pid > 0 && !eligibleSet.contains(pid) {
            Log.info("SIGCONT \(pid) skipped: process is not stopped or exited")
        }
        signal(eligible, SIGCONT, "SIGCONT")
    }

    static func suspendable(
        pids: [Int32],
        expectedParents: [Int32: Int32],
        stateLookup: StateLookup
    ) -> [Int32] {
        pids.filter { pid in
            guard pid > 0, let expected = expectedParents[pid], let state = stateLookup(pid) else { return false }
            return state.ppid == expected
        }
    }

    static func resumable(pids: [Int32], stateLookup: StateLookup) -> [Int32] {
        pids.filter { pid in
            guard pid > 0, let state = stateLookup(pid) else { return false }
            return state.stopped
        }
    }

    private static func kernelState(pid: Int32) -> ProcessSignalState? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return ProcessSignalState(
            ppid: Int32(bitPattern: info.pbi_ppid),
            stopped: info.pbi_status == UInt32(SSTOP)
        )
    }

    private func signal(_ pids: [Int32], _ sig: Int32, _ name: String) {
        for pid in pids where pid > 0 {
            if kill(pid, sig) != 0 {
                let err = errno
                if err != ESRCH {
                    Log.error("\(name) \(pid) failed: \(String(cString: strerror(err)))")
                }
            }
        }
    }
}
