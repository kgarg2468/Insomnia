import AppKit
import Darwin
import Foundation

/// One process as seen by the kernel: enough to rebuild parent/child trees.
struct ProcessEntry: Sendable, Equatable, Hashable {
    let pid: Int32
    let ppid: Int32
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

    init(bundleId: String, name: String, pids: [Int32], expectedParents: [Int32: Int32] = [:]) {
        self.bundleId = bundleId
        self.name = name
        self.pids = pids
        self.expectedParents = expectedParents
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
    /// Several running instances of one bundle id become one group.
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
                    pids.append(pid)
                }
            }
            var expectedParents: [Int32: Int32] = [:]
            for process in processes where pids.contains(process.pid) {
                expectedParents[process.pid] = process.ppid
            }
            out.append(FreezeGroup(bundleId: id, name: instances[0].name, pids: pids, expectedParents: expectedParents))
        }
        return out
    }
}

/// Finds and stops whole app process trees.
protocol Freezing: Sendable {
    /// Groups for the given bundle ids that are running right now.
    func plan(bundleIds: [String], config: Config, applyDenylist: Bool) -> [FreezeGroup]
    func suspend(pids: [Int32], expectedParents: [Int32: Int32])
    func resume(pids: [Int32])
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

    func suspend(pids: [Int32], expectedParents: [Int32: Int32]) {
        control.suspend(pids: pids, expectedParents: expectedParents)
    }
    func resume(pids: [Int32]) { control.resume(pids: pids) }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map {
            RunningApp(pid: $0.processIdentifier, bundleId: $0.bundleIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)")
        }
    }

    /// Every process on the system as (pid, ppid), via sysctl KERN_PROC_ALL.
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
        for i in 0..<count {
            let p = buffer[i]
            out.append(ProcessEntry(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid))
        }
        return out
    }
}
