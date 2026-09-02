import Darwin
import Foundation

/// Sending signals to processes Insomnia froze. Tree discovery and the
/// denylist live in `Freezer`; this is only the signal layer.
protocol ProcessSignaling: Sendable {
    /// SIGSTOP each pid. Missing or foreign pids are ignored.
    func suspend(pids: [Int32])
    /// SIGCONT each pid. Missing or foreign pids are ignored.
    func resume(pids: [Int32])
}

struct SignalProcessControl: ProcessSignaling {
    func suspend(pids: [Int32]) {
        signal(pids, SIGSTOP, "SIGSTOP")
    }

    func resume(pids: [Int32]) {
        signal(pids, SIGCONT, "SIGCONT")
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
