import Foundation
import QuartzCore
import os

// DIAG: everything in this file is temporary diagnostics. Remove the file,
// the `Diag.log` call sites and the `watchdog` property together.

/// DIAG: one line per event, `DIAG <monotonic ms> <message>`, to the unified
/// log only (not insomnia.log: `Log.info` opens the file on every line,
/// which is itself a stall on the hot paths these lines sit on).
nonisolated enum Diag {
    static var nowMs: Double { CACurrentMediaTime() * 1000 }

    static func log(_ message: String) {
        let stamp = String(format: "%.1f", nowMs)
        Log.logger.info("DIAG \(stamp, privacy: .public) \(message, privacy: .public)")
    }
}

/// DIAG: measures how long the main queue takes to service a tiny block.
///
/// A utility-queue timer fires every 8 ms. When no probe is pending it
/// enqueues one on the main queue, recording when; when one is pending it
/// measures how long it has waited. The first time that wait crosses
/// `stallThresholdMs` it logs `DIAG stall <ms>` (once per stall, from the
/// background side, so the line lands while the stall is still going); the
/// probe itself logs `DIAG stall end <ms>` with the total wait when the main
/// queue finally drains it. Nothing here ever blocks the main thread.
@MainActor
final class MainThreadWatchdog {
    nonisolated static let intervalMs = 8
    nonisolated static let stallThresholdMs: Double = 40

    private struct State: Sendable {
        /// When the pending probe was enqueued (`CACurrentMediaTime`), if any.
        var pendingSince: CFTimeInterval?
        /// Whether the pending probe's stall has already been logged.
        var reported = false
    }

    private enum Tick {
        case enqueue
        case stall(ms: Double)
        case wait
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timer: DispatchSourceTimer

    init() {
        let queue = DispatchQueue(label: "insomnia.diag.watchdog", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Self.intervalMs), leeway: .milliseconds(1))
        let state = state
        // `@Sendable`: written inside a main-actor init, the closure would
        // otherwise inherit main-actor isolation and trap when libdispatch
        // runs it on the utility queue.
        timer.setEventHandler { @Sendable in
            let now = CACurrentMediaTime()
            // Either enqueue a probe (none pending) or check on the pending one.
            let tick: Tick = state.withLock { s in
                guard let since = s.pendingSince else {
                    s.pendingSince = now
                    s.reported = false
                    return .enqueue
                }
                let waited = (now - since) * 1000
                guard waited > Self.stallThresholdMs, !s.reported else { return .wait }
                s.reported = true
                return .stall(ms: waited)
            }
            switch tick {
            case .wait:
                return
            case let .stall(ms):
                Diag.log(String(format: "stall %.1f", ms))
            case .enqueue:
                DispatchQueue.main.async {
                    let served = CACurrentMediaTime()
                    let (since, reported) = state.withLock { s -> (CFTimeInterval?, Bool) in
                        defer { s.pendingSince = nil; s.reported = false }
                        return (s.pendingSince, s.reported)
                    }
                    guard let since, reported else { return }
                    Diag.log(String(format: "stall end %.1f", (served - since) * 1000))
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer.cancel()
    }
}
