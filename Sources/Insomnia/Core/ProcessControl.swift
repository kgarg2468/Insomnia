import Darwin
import Foundation

/// Sending signals to processes Insomnia froze.
/// PR2: adds `suspend(pids:)`, responsible-pid tree discovery and the denylist
/// (Freezer). This PR only needs `resume` so reconcile can un-freeze whatever
/// a crashed run left stopped.
protocol ProcessSignaling: Sendable {
    /// SIGCONT each pid. Missing or foreign pids are ignored.
    func resume(pids: [Int32])
}

struct SignalProcessControl: ProcessSignaling {
    func resume(pids: [Int32]) {
        for pid in pids where pid > 0 {
            if kill(pid, SIGCONT) != 0 {
                let err = errno
                if err != ESRCH {
                    Log.error("SIGCONT \(pid) failed: \(String(cString: strerror(err)))")
                }
            }
        }
    }
}
