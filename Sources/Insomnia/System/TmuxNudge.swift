import Foundation

/// Spec section 7: `tmux send-keys -t <target> "continue" Enter` for every
/// tagged pane after a long outage. Failures are logged, never thrown.
///
/// Automation boundary: a keystroke that has reached tmux cannot be taken
/// back. So the loop re-checks, before *every* target, that its task is not
/// cancelled and that the session which asked for the nudge still exists,
/// and the live runner checks cancellation again before each command. The
/// live runner also refuses a pane whose state it cannot verify or where
/// keys would not reach the program (dead, in copy/choose mode, input off).
/// Residual risk, not closable from outside tmux: the flags above cannot
/// show text the pane's program has buffered but not yet submitted. If a
/// half-typed line is pending, `continue` is appended to it and the whole
/// line is submitted by the Enter that follows.
struct TmuxNudge: Sendable {
    static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// `display-message -p -F` format the live runner reads before sending.
    static let paneStateFormat = "#{pane_dead} #{pane_in_mode} #{pane_input_off}"

    typealias Runner = @Sendable (_ target: String) async throws -> Bool
    /// Asked before each target; `false` ends the nudge because the session
    /// that requested it is gone.
    typealias Permission = @MainActor @Sendable () -> Bool

    enum PaneCheck: Equatable, Sendable {
        case ready
        case skip(reason: String)
    }

    let run: Runner

    init(run: Runner? = nil) {
        self.run = run ?? TmuxNudge.liveRunner
    }

    /// Returns the number of targets that accepted the keystroke.
    @discardableResult
    func nudge(targets: [String], permitted: @escaping Permission = { true }) async -> Int {
        var count = 0
        for target in targets where !target.isEmpty {
            if Task.isCancelled {
                Log.info("tmux nudge to \(target) skipped: cancelled")
                break
            }
            guard await permitted() else {
                Log.info("tmux nudge to \(target) skipped: session stopped")
                break
            }
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

    /// Decides from `display-message -p -F paneStateFormat` output whether
    /// `send-keys` may run. Anything but three clean 0/1 flags is
    /// unverifiable and skipped: tmux prints blank fields, with exit 0, for
    /// a target it cannot resolve.
    static func check(paneState output: String) -> PaneCheck {
        let fields = output.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        guard fields.count == 3, fields.allSatisfy({ $0 == "0" || $0 == "1" }) else {
            let shown = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .skip(reason: "pane state unverifiable (\(shown.isEmpty ? "no such pane" : shown))")
        }
        if fields[0] == "1" { return .skip(reason: "pane is dead") }
        if fields[1] == "1" { return .skip(reason: "pane is in copy/choose mode; keys would not reach the program") }
        if fields[2] == "1" { return .skip(reason: "pane input is disabled") }
        return .ready
    }

    static let liveRunner: Runner = makeLiveRunner()

    /// `socketName` selects a private tmux server (`tmux -L`); nil is the
    /// user's default server.
    static func makeLiveRunner(socketName: String? = nil) -> Runner {
        { target in
            guard let tmux = Shell.locate(candidates) else {
                throw ShellError.launchFailed(exe: "tmux", underlying: "not found in \(candidates.joined(separator: ", "))")
            }
            let server = socketName.map { ["-L", $0] } ?? []
            try Task.checkCancellation()
            let state = try await Shell.run(tmux, server + ["display-message", "-p", "-t", target, "-F", paneStateFormat], timeout: 5)
            guard state.succeeded else {
                Log.error("tmux display-message -t \(target): \(state.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                return false
            }
            if case let .skip(reason) = check(paneState: state.stdout) {
                Log.error("tmux nudge to \(target) skipped: \(reason)")
                return false
            }
            // The pane can still change between this check and the send.
            try Task.checkCancellation()
            let r = try await Shell.run(tmux, server + ["send-keys", "-t", target, "continue", "Enter"], timeout: 5)
            if !r.succeeded {
                Log.error("tmux send-keys -t \(target): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return r.succeeded
        }
    }
}
