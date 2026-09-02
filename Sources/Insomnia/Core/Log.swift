import Foundation
import os

/// Unified logging plus a plain-text line appended to insomnia.log, which is
/// shared with backstop.sh so one file tells the whole story.
enum Log {
    static let logger = Logger(subsystem: Paths.bundleIdentifier, category: "core")
    private static let lock = NSLock()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append(level: "info", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append(level: "error", message)
    }

    static func append(level: String, _ message: String, paths: Paths = .fromEnvironment()) {
        let now = Date().formatted(.iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false).timeZone(separator: .omitted))
        let line = "\(now) [\(level)] insomnia: \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            let url = paths.logFile
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            logger.error("log append failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
