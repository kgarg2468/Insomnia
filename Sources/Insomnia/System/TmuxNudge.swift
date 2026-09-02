import Foundation

/// Spec section 7: `tmux send-keys -t <target> "continue" Enter` for every
/// tagged pane after a long outage. Failures are logged, never thrown.
struct TmuxNudge: Sendable {
    static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    typealias Runner = @Sendable (_ target: String) async throws -> Bool

    let run: Runner

    init(run: Runner? = nil) {
        self.run = run ?? TmuxNudge.liveRunner
    }

    /// Returns the number of targets that accepted the keystroke.
    @discardableResult
    func nudge(targets: [String]) async -> Int {
        var count = 0
        for target in targets where !target.isEmpty {
            do {
                if try await run(target) {
                    count += 1
                    Log.info("tmux nudge sent to \(target)")
                } else {
                    Log.error("tmux nudge to \(target) rejected")
                }
            } catch {
                Log.error("tmux nudge to \(target) failed: \(error.localizedDescription)")
            }
        }
        return count
    }

    static let liveRunner: Runner = { target in
        guard let tmux = Shell.locate(candidates) else {
            throw ShellError.launchFailed(exe: "tmux", underlying: "not found in \(candidates.joined(separator: ", "))")
        }
        let r = try await Shell.run(tmux, ["send-keys", "-t", target, "continue", "Enter"], timeout: 5)
        if !r.succeeded {
            Log.error("tmux send-keys -t \(target): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r.succeeded
    }
}
