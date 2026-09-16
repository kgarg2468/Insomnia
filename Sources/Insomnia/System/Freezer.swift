import AppKit
import Darwin
import Foundation

/// One process as seen by the kernel: enough to rebuild parent/child trees
/// and to recognise the same process again later.
struct ProcessEntry: Sendable, Equatable, Hashable {
    let pid: Int32
    let ppid: Int32
    let identity: ProcessIdentity
    /// Already stopped when the snapshot was taken (by a debugger, by the
    /// user, by an earlier crash). Never ours to freeze or resume.
    let stopped: Bool

    init(pid: Int32, ppid: Int32, identity: ProcessIdentity, stopped: Bool) {
        self.pid = pid
        self.ppid = ppid
        self.identity = identity
        self.stopped = stopped
    }
}

/// One running GUI app as seen by NSWorkspace.
struct RunningApp: Sendable, Equatable {
    /// `NSApplication.ActivationPolicy` without AppKit: `.regular` is a
    /// Dock app, `.accessory` a menu-bar app, `.prohibited` a background
    /// process that still registered with the workspace.
    enum ActivationPolicy: Sendable, Equatable {
        case regular, accessory, prohibited

        init(_ policy: NSApplication.ActivationPolicy) {
            switch policy {
            case .regular: self = .regular
            case .accessory: self = .accessory
            case .prohibited: self = .prohibited
            @unknown default: self = .prohibited
            }
        }
    }

    let pid: Int32
    let bundleId: String?
    let name: String
    let activationPolicy: ActivationPolicy

    init(pid: Int32, bundleId: String?, name: String, activationPolicy: ActivationPolicy = .regular) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.activationPolicy = activationPolicy
    }
}

/// A whole app (main process plus every descendant) ready to be stopped.
struct FreezeGroup: Sendable, Equatable {
    let bundleId: String
    let name: String
    /// Main pid first, then descendants in discovery order.
    let pids: [Int32]
    /// Kernel parent captured with the process tree, checked again at SIGSTOP.
    let expectedParents: [Int32: Int32]
    /// Start identity per pid, journaled before SIGSTOP and checked again at
    /// SIGSTOP and at SIGCONT.
    let identities: [Int32: ProcessIdentity]

    init(bundleId: String, name: String, pids: [Int32], expectedParents: [Int32: Int32] = [:], identities: [Int32: ProcessIdentity] = [:]) {
        self.bundleId = bundleId
        self.name = name
        self.pids = pids
        self.expectedParents = expectedParents
        self.identities = identities
    }
}

/// Pure planning: denylist, lid-close scope, tree grouping. No process access.
enum FreezePlanner {
    static let dockerBundleId = "com.docker.docker"

    /// Apps the automatic lid-close scope (`Config.freezeAllApps`) leaves
    /// alone even when they are not on the agent list: agent hosts, editors,
    /// terminals, browsers agents drive, VPN and local model runtimes. Code
    /// level, not persisted, because an existing config.json already carries
    /// its own agent list and new defaults never reach it. An explicit
    /// freeze-list entry overrides this set; the hard denylist does not.
    static let builtInProtected: Set<String> = [
        // Editors and agent hosts (verified bundle ids)
        "com.microsoft.VSCode",             // Visual Studio Code
        "com.todesktop.230313mzl4w4u92",    // Cursor
        "dev.zed.Zed",                      // Zed
        "com.google.antigravity",           // Antigravity
        "com.anthropic.claudefordesktop",   // Claude
        "com.openai.codex",                 // ChatGPT (hosts Codex and computer use)
        "com.conductor.app",                // Conductor
        "com.t3tools.t3code",               // T3 Code (Nightly)
        "com.t3tools.t3code.reasoning",     // T3 Code (Reasoning)
        // Terminals
        "dev.warp.Warp-Stable",             // Warp
        "com.mitchellh.ghostty",            // Ghostty
        "com.googlecode.iterm2",            // iTerm2
        // Browsers agents drive
        "company.thebrowser.Browser",       // Arc
        "com.google.Chrome",                // Google Chrome
        "org.chromium.Chromium",            // Chromium
        // VPN and local model runtimes
        "io.tailscale.ipn.macsys",          // Tailscale
        "ai.elementlabs.lmstudio",          // LM Studio
        "com.electron.ollama",              // Ollama
        // Docker Desktop's Electron front end registers under its own id
        // (observed running alongside com.docker.docker); the Docker rule
        // owns the whole tree, the automatic scope must not.
        "com.electron.dockerdesktop",       // Docker Desktop UI
        // Dock apps that host services agents depend on (SSH agent, local
        // databases, container runtimes). Unverified ids, see below.
        "com.1password.1password",          // 1Password (SSH agent lives in the app; unverified)
        "com.bitwarden.desktop",            // Bitwarden (unverified)
        "com.postgresapp.Postgres2",        // Postgres.app (unverified)
        "dev.orbstack.OrbStack",            // OrbStack (unverified)
        // Unverified: bundle ids taken from vendor documentation, not from a
        // running copy on this machine.
        "com.exafunction.windsurf",         // Windsurf (unverified)
        "com.jetbrains.intellij",           // IntelliJ IDEA (unverified)
        "com.jetbrains.pycharm",            // PyCharm (unverified)
        "com.jetbrains.WebStorm",           // WebStorm (unverified)
        "com.jetbrains.goland",             // GoLand (unverified)
        "com.jetbrains.CLion",              // CLion (unverified)
        "com.jetbrains.rider",              // Rider (unverified)
        "com.jetbrains.PhpStorm",           // PhpStorm (unverified)
    ]

    /// Dock apps the automatic scope would freeze right now, sorted by name
    /// and de-duplicated by bundle id: `activationPolicy == .regular` with a
    /// bundle id, minus the hard denylist, minus `builtInProtected`, minus
    /// anything already on the explicit freeze list. Empty when the toggle
    /// is off. Accessory (menu-bar) apps are never picked up; put them on
    /// the freeze list by hand.
    static func automaticCandidates(config: Config, apps: [RunningApp], selfBundleId: String = Paths.bundleIdentifier) -> [RunningApp] {
        guard config.freezeAllApps else { return [] }
        let explicit = Set(config.freezeList)
        var seen: Set<String> = []
        var out: [RunningApp] = []
        for app in apps where app.activationPolicy == .regular {
            guard let id = app.bundleId, !seen.contains(id), !explicit.contains(id) else { continue }
            guard !isDenied(id, config: config, selfBundleId: selfBundleId), !builtInProtected.contains(id) else { continue }
            seen.insert(id)
            out.append(app)
        }
        return out.sorted {
            switch $0.name.localizedCaseInsensitiveCompare($1.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return ($0.bundleId ?? "") < ($1.bundleId ?? "")
            }
        }
    }

    /// Everything the config says to freeze on lid close: the explicit
    /// freeze list first, in its own order, then the automatic candidates.
    /// De-duplicated. The hard denylist is enforced by `groups`, as for the
    /// explicit list today, so a denied explicit entry is still logged there.
    static func lidCloseBundleIds(config: Config, apps: [RunningApp], selfBundleId: String = Paths.bundleIdentifier) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for id in config.freezeList where !seen.contains(id) {
            seen.insert(id)
            out.append(id)
        }
        let automatic = automaticCandidates(config: config, apps: apps, selfBundleId: selfBundleId)
        if config.freezeAllApps {
            let names = automatic.map(\.name)
            Log.info("freeze-all: automatic candidates: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        for app in automatic {
            guard let id = app.bundleId, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// Spec section 4 hard denylist: `com.apple.*`, Insomnia itself, Docker
    /// Desktop (handled by the Docker rule) and everything in the agent list.
    static func isDenied(_ bundleId: String, config: Config, selfBundleId: String = Paths.bundleIdentifier) -> Bool {
        if bundleId.hasPrefix("com.apple.") { return true }
        if bundleId == selfBundleId { return true }
        if bundleId == dockerBundleId { return true }
        if config.agentList.contains(bundleId) { return true }
        return false
    }

    /// `root` followed by every transitive child found in `processes`.
    /// Cycles (impossible in practice, but cheap to guard) are ignored.
    static func tree(root: Int32, in processes: [ProcessEntry]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for p in processes where p.pid != p.ppid {
            children[p.ppid, default: []].append(p.pid)
        }
        var result: [Int32] = [root]
        var seen: Set<Int32> = [root]
        var queue: [Int32] = [root]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in children[parent] ?? [] where !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// One group per requested bundle id that is running and not denied.
    /// Several running instances of one bundle id become one group. A
    /// process that is already stopped is left out: Insomnia did not stop it
    /// and must never resume it.
    static func groups(
        bundleIds: [String],
        apps: [RunningApp],
        processes: [ProcessEntry],
        config: Config,
        selfBundleId: String = Paths.bundleIdentifier,
        applyDenylist: Bool = true
    ) -> [FreezeGroup] {
        var out: [FreezeGroup] = []
        var done: Set<String> = []
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for id in bundleIds where !done.contains(id) {
            done.insert(id)
            if applyDenylist, isDenied(id, config: config, selfBundleId: selfBundleId) {
                Log.info("freeze: \(id) is on the denylist, skipped")
                continue
            }
            let instances = apps.filter { $0.bundleId == id }
            guard !instances.isEmpty else { continue }
            var pids: [Int32] = []
            for app in instances {
                for pid in tree(root: app.pid, in: processes) where !pids.contains(pid) {
                    if byPid[pid]?.stopped == true {
                        Log.info("freeze: pid \(pid) of \(instances[0].name) is already stopped, not ours; skipped")
                        continue
                    }
                    pids.append(pid)
                }
            }
            var expectedParents: [Int32: Int32] = [:]
            var identities: [Int32: ProcessIdentity] = [:]
            for process in processes where pids.contains(process.pid) {
                expectedParents[process.pid] = process.ppid
                identities[process.pid] = process.identity
            }
            out.append(FreezeGroup(bundleId: id, name: instances[0].name, pids: pids, expectedParents: expectedParents, identities: identities))
        }
        return out
    }
}

/// Finds and stops whole app process trees.
protocol Freezing: Sendable {
    /// Groups for the given bundle ids that are running right now.
    func plan(bundleIds: [String], config: Config, applyDenylist: Bool) -> [FreezeGroup]
    /// Everything the config says to freeze right now: the freeze list plus,
    /// with `freezeAllApps` on, every other Dock app outside the denylist
    /// and the built-in protected set (`FreezePlanner.lidCloseBundleIds`).
    func plan(config: Config) -> [FreezeGroup]
    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport
    func resume(_ processes: [FrozenProcess]) -> ResumeReport
}

extension Freezing {
    func plan(bundleIds: [String], config: Config) -> [FreezeGroup] {
        plan(bundleIds: bundleIds, config: config, applyDenylist: true)
    }
}

/// Live implementation over NSWorkspace + sysctl KERN_PROC_ALL.
struct Freezer: Freezing {
    let control: any ProcessSignaling
    let selfBundleId: String

    init(control: any ProcessSignaling = SignalProcessControl(), selfBundleId: String = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier) {
        self.control = control
        self.selfBundleId = selfBundleId
    }

    func plan(bundleIds: [String], config: Config, applyDenylist: Bool) -> [FreezeGroup] {
        FreezePlanner.groups(
            bundleIds: bundleIds,
            apps: Self.runningApps(),
            processes: Self.processSnapshot(),
            config: config,
            selfBundleId: selfBundleId,
            applyDenylist: applyDenylist
        )
    }

    func plan(config: Config) -> [FreezeGroup] {
        let apps = Self.runningApps()
        return FreezePlanner.groups(
            bundleIds: FreezePlanner.lidCloseBundleIds(config: config, apps: apps, selfBundleId: selfBundleId),
            apps: apps,
            processes: Self.processSnapshot(),
            config: config,
            selfBundleId: selfBundleId,
            applyDenylist: true
        )
    }

    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        control.suspend(processes, expectedParents: expectedParents)
    }
    func resume(_ processes: [FrozenProcess]) -> ResumeReport { control.resume(processes) }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map {
            RunningApp(
                pid: $0.processIdentifier,
                bundleId: $0.bundleIdentifier,
                name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)",
                activationPolicy: RunningApp.ActivationPolicy($0.activationPolicy)
            )
        }
    }

    /// Every process on the system with parent, start identity and stopped
    /// state, via sysctl KERN_PROC_ALL.
    static func processSnapshot() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            Log.error("sysctl KERN_PROC_ALL size failed: \(String(cString: strerror(errno)))")
            return []
        }
        // Leave headroom: processes can appear between the two calls.
        size += size / 4
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = size / stride + 1
        let buffer = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        size = capacity * stride
        guard sysctl(&mib, UInt32(mib.count), buffer, &size, nil, 0) == 0 else {
            Log.error("sysctl KERN_PROC_ALL failed: \(String(cString: strerror(errno)))")
            return []
        }
        let count = size / stride
        var out: [ProcessEntry] = []
        out.reserveCapacity(count)
        let boot = SignalProcessControl.bootSession
        for i in 0..<count {
            let p = buffer[i]
            let started = p.kp_proc.p_starttime
            out.append(ProcessEntry(
                pid: p.kp_proc.p_pid,
                ppid: p.kp_eproc.e_ppid,
                identity: ProcessIdentity(
                    startedAt: Int64(started.tv_sec),
                    startedAtMicros: Int32(truncatingIfNeeded: started.tv_usec),
                    bootSession: boot
                ),
                stopped: p.kp_proc.p_stat == UInt8(SSTOP)
            ))
        }
        return out
    }
}
