import Foundation

/// File trigger for the lid-close action path, for release validation on a
/// machine whose lid stays open (scripts/simulate-lid.sh). Watches the
/// support directory; when the trigger file appears it is read, deleted
/// and delivered as a lid event. Same trust boundary as config.json: only
/// this user can write the directory. Only active while AppServices runs,
/// that is while a session is active.
///
/// The hardware reading (`LidObserver.readClamshellState`, used by
/// `refreshInstant` and reconcile) still reflects the real lid; this only
/// drives the close/open actions.
@MainActor
final class LidSimulation {
    /// Called on the main actor with `true` for closed.
    var onEvent: ((Bool) -> Void)?

    private var source: (any DispatchSourceFileSystemObject)?
    private var file: URL?

    init() {}

    func start(directory: URL, file: URL) {
        guard source == nil else { return }
        self.file = file
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("lid simulation: cannot watch \(directory.path): \(String(cString: strerror(errno)))")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in
            Task { @MainActor in self?.consume() }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
        // A trigger left over from before the session started is stale
        // (scripts/simulate-lid.sh says so): consumed and ignored, never
        // acted on, so an old "closed" cannot darken and freeze a session
        // that just started.
        while let text = claim() {
            Log.info("lid simulation: ignored stale trigger \"\(text)\"")
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        file = nil
    }

    /// Delivers every trigger on disk. The watcher calls this on each
    /// directory write; internal so tests can drive it without the watcher.
    /// Directory events coalesce, so a "closed" and an "open" written back
    /// to back can arrive as one event: keep claiming until the path is
    /// empty, so the pair is never cut to its first half.
    func consume() {
        while let text = claim() {
            switch text {
            case "closed":
                Log.info("lid SIMULATED closed (file trigger)")
                onEvent?(true)
            case "open":
                Log.info("lid SIMULATED open (file trigger)")
                onEvent?(false)
            case let other:
                Log.error("lid simulation: ignoring trigger \"\(other)\" (expected closed or open)")
            }
        }
    }

    // MARK: Private

    /// Claims the trigger before reading it: `rename(2)` to a per-process
    /// path is atomic, so two readers cannot both act on one write, and it
    /// replaces a claim file a crash left behind. ENOENT means there is no
    /// trigger (or another reader claimed it first). The claimed file is
    /// read and unlinked. nil when nothing was claimed.
    private func claim() -> String? {
        guard let file else { return nil }
        let claimed = file.appendingPathExtension("claimed.\(getpid())")
        guard rename(file.path, claimed.path) == 0 else {
            let code = errno
            if code != ENOENT {
                Log.error("lid simulation: cannot claim \(file.path): \(String(cString: strerror(code)))")
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claimed) }
        let text = (try? String(contentsOf: claimed, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
