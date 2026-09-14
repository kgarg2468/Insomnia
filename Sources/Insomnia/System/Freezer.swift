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
    let pid: Int32
    let bundleId: String?
    let name: String
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

/// Pure planning: denylist, tree grouping. No process access.
enum FreezePlanner {
    static let dockerBundleId = "com.docker.docker"

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

    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        control.suspend(processes, expectedParents: expectedParents)
    }
    func resume(_ processes: [FrozenProcess]) -> ResumeReport { control.resume(processes) }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map {
            RunningApp(pid: $0.processIdentifier, bundleId: $0.bundleIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)")
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
