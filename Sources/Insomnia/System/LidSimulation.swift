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
        // A trigger written before the session started still counts.
        consume()
    }

    func stop() {
        source?.cancel()
        source = nil
        file = nil
    }

    // MARK: Private

    private func consume() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: file)
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
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
