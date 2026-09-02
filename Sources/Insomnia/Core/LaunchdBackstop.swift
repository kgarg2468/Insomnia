import Foundation

/// Keeps the launchd agent that runs backstop.sh in sync with the session
/// deadline, so sleep is restored even if Insomnia is gone.
protocol BackstopScheduling: Sendable {
    /// Fire once at (just after) `endsAt`, and at every load.
    func schedule(endsAt: Date) async throws
    /// Drop the calendar trigger, keep RunAtLoad.
    func clear() async throws
}

struct LaunchdBackstop: BackstopScheduling {
    static let launchctl = "/bin/launchctl"

    let plistURL: URL
    let scriptPath: String
    let label: String
    let uid: uid_t

    init(paths: Paths, label: String = Paths.backstopLabel, uid: uid_t = getuid()) {
        self.plistURL = paths.backstopPlist
        self.scriptPath = paths.backstopScript.path
        self.label = label
        self.uid = uid
    }

    func schedule(endsAt: Date) async throws {
        try writePlist(endsAt: endsAt)
        await reload()
    }

    func clear() async throws {
        try writePlist(endsAt: nil)
        await reload()
    }

    // MARK: Plist

    /// Pure builder, testable without launchd. When `endsAt` is given the
    /// calendar interval is one minute after it so the session timer always
    /// gets first go.
    static func plistDictionary(label: String, scriptPath: String, endsAt: Date?, calendar: Calendar = .current) -> [String: Any] {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptPath],
            "RunAtLoad": true,
        ]
        if let endsAt {
            let fire = endsAt.addingTimeInterval(60)
            let c = calendar.dateComponents([.minute, .hour, .day, .month], from: fire)
            dict["StartCalendarInterval"] = [
                "Minute": c.minute ?? 0,
                "Hour": c.hour ?? 0,
                "Day": c.day ?? 1,
                "Month": c.month ?? 1,
            ]
        }
        return dict
    }

    func writePlist(endsAt: Date?) throws {
        let dict = Self.plistDictionary(label: label, scriptPath: scriptPath, endsAt: endsAt)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    // MARK: launchctl

    /// bootout (ignored if not loaded) then bootstrap. RunAtLoad means the
    /// script runs immediately on every reload; it is a no-op while the
    /// session on disk is valid.
    private func reload() async {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            Log.error("backstop.sh not installed at \(scriptPath); run scripts/install.sh (launchd agent not loaded)")
            return
        }
        let domain = "gui/\(uid)"
        do {
            _ = try await Shell.run(Self.launchctl, ["bootout", domain, plistURL.path])
            let r = try await Shell.run(Self.launchctl, ["bootstrap", domain, plistURL.path])
            if !r.succeeded {
                Log.error("launchctl bootstrap failed (\(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            Log.error("launchctl failed: \(error.localizedDescription)")
        }
    }
}
