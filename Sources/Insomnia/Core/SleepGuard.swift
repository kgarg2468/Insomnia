import Foundation

/// The only two things Insomnia ever does as root, both through the four
/// sudoers-allowed pmset commands written by install.sh.
protocol SleepGuarding: Sendable {
    func setSleepDisabled(_ disabled: Bool) async throws
    func isSleepDisabled() async throws -> Bool
    func setLowPowerMode(_ on: Bool) async throws
}

struct SleepGuardError: Error, LocalizedError, Sendable {
    let command: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var msg = "`\(command)` failed with status \(status)"
        if !detail.isEmpty { msg += ": \(detail)" }
        if detail.contains("password") || detail.contains("sudo") {
            msg += " (run scripts/install.sh to install /etc/sudoers.d/insomnia)"
        }
        return msg
    }
}

/// `sudo -n pmset …`. Never prompts; if the sudoers rule is missing the call
/// fails fast with a readable error instead of hanging on a password prompt.
struct PmsetSleepGuard: SleepGuarding {
    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"

    func setSleepDisabled(_ disabled: Bool) async throws {
        try await sudoPmset(["-a", "disablesleep", disabled ? "1" : "0"])
    }

    func setLowPowerMode(_ on: Bool) async throws {
        try await sudoPmset(["-b", "lowpowermode", on ? "1" : "0"])
    }

    func isSleepDisabled() async throws -> Bool {
        let r = try await Shell.run(Self.pmset, ["-g"])
        guard r.succeeded else {
            throw SleepGuardError(command: "pmset -g", status: r.status, stderr: r.stderr)
        }
        return Self.parseSleepDisabled(r.stdout)
    }

    /// True when `pmset -g` output has a line whose first token is
    /// `SleepDisabled` and whose value is `1`.
    static func parseSleepDisabled(_ output: String) -> Bool {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("SleepDisabled") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "SleepDisabled" else { continue }
            return parts[1] == "1"
        }
        return false
    }

    private func sudoPmset(_ args: [String]) async throws {
        let full = [Self.pmset] + args
        let r = try await Shell.run(Self.sudo, ["-n"] + full)
        guard r.succeeded else {
            throw SleepGuardError(command: "sudo -n \(full.joined(separator: " "))", status: r.status, stderr: r.stderr)
        }
    }
}
