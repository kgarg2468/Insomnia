import AppKit
import Foundation

/// Spec section 5: Chromium browsers throttle occluded windows unless
/// launched with both flags. Detect, and relaunch with them on request.
enum ChromiumFlags {
    static let occluded = "--disable-backgrounding-occluded-windows"
    static let renderer = "--disable-renderer-backgrounding"
    static let required = [occluded, renderer]

    static let knownBrowsers: [String] = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
    ]

    /// Known Chromium ids plus any agent-list id mentioning chrome/chromium.
    static func chromiumBundleIds(config: Config) -> [String] {
        var ids = knownBrowsers
        for id in config.agentList {
            let l = id.lowercased()
            if (l.contains("chrome") || l.contains("chromium")), !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Splits a `ps -o args=` line into arguments, honouring single and
    /// double quotes and backslash escapes, so a flag that only appears
    /// inside another argument's quoted value is not counted.
    static func tokenize(_ args: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSingle = false, inDouble = false, escaped = false, hasToken = false
        for ch in args {
            if escaped {
                current.append(ch)
                escaped = false
                hasToken = true
                continue
            }
            switch ch {
            case "\\" where !inSingle:
                escaped = true
            case "'" where !inDouble:
                inSingle.toggle()
                hasToken = true
            case "\"" where !inSingle:
                inDouble.toggle()
                hasToken = true
            case " ", "\t", "\n":
                if inSingle || inDouble {
                    current.append(ch)
                } else if hasToken {
                    out.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { out.append(current) }
        return out
    }

    /// True when both required flags are present as their own arguments.
    static func hasBothFlags(args: String) -> Bool {
        let tokens = Set(tokenize(args).map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0 })
        return required.allSatisfy { tokens.contains($0) }
    }

    /// Arguments worth carrying over on relaunch so the same profile opens.
    static func preservedArgs(args: String) -> [String] {
        tokenize(args).dropFirst().filter {
            $0.hasPrefix("--user-data-dir=") || $0.hasPrefix("--profile-directory=")
        }
    }
}

struct BrowserStatus: Sendable, Equatable {
    let bundleId: String
    let name: String
    let pid: Int32
    let unthrottled: Bool
}

/// Waits for AppKit termination notifications with one timeout event. This
/// keeps relaunch event-driven instead of waking every few hundred ms.
@MainActor
private final class ApplicationTerminationWaiter {
    private let applications: [NSRunningApplication]
    private var pending: Set<Int32> = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(applications: [NSRunningApplication]) {
        self.applications = applications
    }

    func terminateAndWait(timeout: TimeInterval) async -> Bool {
        pending = Set(applications.lazy.filter { !$0.isTerminated }.map(\.processIdentifier))
        guard !pending.isEmpty else { return true }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let center = NSWorkspace.shared.notificationCenter
            observer = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                Task { @MainActor [weak self] in self?.applicationTerminated(pid) }
            }

            let timeoutTimer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(allTerminated: false) }
            }
            RunLoop.main.add(timeoutTimer, forMode: .common)
            timer = timeoutTimer

            for application in applications where !application.isTerminated {
                application.terminate()
            }
        }
    }

    private func applicationTerminated(_ pid: Int32) {
        pending.remove(pid)
        if pending.isEmpty { finish(allTerminated: true) }
    }

    private func finish(allTerminated: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.invalidate()
        timer = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        continuation.resume(returning: allTerminated)
    }
}

@MainActor
final class BrowserThrottle {
    typealias ArgsReader = @Sendable (_ pid: Int32) async throws -> String

    private(set) var statuses: [BrowserStatus] = []
    /// Display names of running Chromium browsers missing either flag.
    var throttledBrowsers: [String] { statuses.filter { !$0.unthrottled }.map(\.name) }

    private let readArgs: ArgsReader

    init(readArgs: ArgsReader? = nil) {
        self.readArgs = readArgs ?? BrowserThrottle.psArgs
    }

    /// Inspect every running Chromium browser's main process.
    @discardableResult
    func scan(config: Config) async -> [BrowserStatus] {
        let ids = ChromiumFlags.chromiumBundleIds(config: config)
        var out: [BrowserStatus] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, ids.contains(id) else { continue }
            let pid = app.processIdentifier
            let name = app.localizedName ?? id
            do {
                let args = try await readArgs(pid)
                out.append(BrowserStatus(bundleId: id, name: name, pid: pid, unthrottled: ChromiumFlags.hasBothFlags(args: args)))
            } catch {
                Log.error("browser throttle: could not read args of \(name): \(error.localizedDescription)")
            }
        }
        statuses = out
        if !throttledBrowsers.isEmpty {
            Log.info("throttled browsers: \(throttledBrowsers.joined(separator: ", "))")
        }
        return out
    }

    /// Quit the browser, wait up to 10 s for it to exit, relaunch it with
    /// both flags (and the same profile arguments it had).
    func relaunchUnthrottled(bundleId: String) async {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleId }
        var extra: [String] = []
        if let main = running.first {
            if let args = try? await readArgs(main.processIdentifier) {
                extra = ChromiumFlags.preservedArgs(args: args)
            }
        }
        let terminated = await ApplicationTerminationWaiter(applications: running).terminateAndWait(timeout: 10)
        if !terminated {
            Log.error("relaunch: \(bundleId) did not quit within 10 s; launching anyway")
        }
        do {
            let r = try await Shell.run("/usr/bin/open", ["-b", bundleId, "--args"] + ChromiumFlags.required + extra, timeout: 15)
            if r.succeeded {
                Log.info("relaunched \(bundleId) unthrottled")
            } else {
                Log.error("open -b \(bundleId) failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            Log.error("open -b \(bundleId) failed: \(error.localizedDescription)")
        }
    }

    static let psArgs: ArgsReader = { pid in
        let r = try await Shell.run("/bin/ps", ["-o", "args=", "-p", String(pid)], timeout: 5)
        return r.stdout
    }
}
