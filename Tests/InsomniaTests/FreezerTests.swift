import XCTest
@testable import Insomnia

final class FreezerTests: XCTestCase {
    // Slack main (100) with helpers 101, 102 (child of 101), 103; an unrelated
    // process 200 under launchd; Insomnia itself at 300.
    let processes: [ProcessEntry] = [
        ProcessEntry(pid: 1, ppid: 0),
        ProcessEntry(pid: 100, ppid: 1),
        ProcessEntry(pid: 101, ppid: 100),
        ProcessEntry(pid: 102, ppid: 101),
        ProcessEntry(pid: 103, ppid: 100),
        ProcessEntry(pid: 200, ppid: 1),
        ProcessEntry(pid: 300, ppid: 1),
        ProcessEntry(pid: 400, ppid: 1),
        ProcessEntry(pid: 401, ppid: 400),
    ]
    let apps: [RunningApp] = [
        RunningApp(pid: 100, bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
        RunningApp(pid: 200, bundleId: "com.apple.Safari", name: "Safari"),
        RunningApp(pid: 300, bundleId: Paths.bundleIdentifier, name: "Insomnia"),
        RunningApp(pid: 400, bundleId: "com.docker.docker", name: "Docker"),
    ]

    func testTreeIncludesMainAndAllHelpersOnly() {
        XCTAssertEqual(FreezePlanner.tree(root: 100, in: processes), [100, 101, 103, 102])
        XCTAssertEqual(FreezePlanner.tree(root: 200, in: processes), [200])
    }

    func testGroupsMainPlusHelpersExcludingUnrelated() {
        let groups = FreezePlanner.groups(bundleIds: ["com.tinyspeck.slackmacgap"], apps: apps, processes: processes, config: Config())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].bundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(groups[0].name, "Slack")
        XCTAssertEqual(Set(groups[0].pids), [100, 101, 102, 103])
        XCTAssertFalse(groups[0].pids.contains(200))
    }

    func testNotRunningAppYieldsNoGroup() {
        let groups = FreezePlanner.groups(bundleIds: ["net.whatsapp.WhatsApp"], apps: apps, processes: processes, config: Config())
        XCTAssertTrue(groups.isEmpty)
    }

    func testDenylistApple() {
        XCTAssertTrue(FreezePlanner.isDenied("com.apple.Safari", config: Config()))
        XCTAssertTrue(FreezePlanner.isDenied("com.apple.finder", config: Config()))
        XCTAssertFalse(FreezePlanner.isDenied("com.tinyspeck.slackmacgap", config: Config()))
    }

    func testDenylistSelf() {
        XCTAssertTrue(FreezePlanner.isDenied(Paths.bundleIdentifier, config: Config()))
        XCTAssertTrue(FreezePlanner.isDenied("dev.other.insomnia", config: Config(), selfBundleId: "dev.other.insomnia"))
    }

    func testDenylistDocker() {
        var c = Config()
        c.agentList = []
        XCTAssertTrue(FreezePlanner.isDenied("com.docker.docker", config: c))
        let denied = FreezePlanner.groups(bundleIds: ["com.docker.docker"], apps: apps, processes: processes, config: c)
        XCTAssertTrue(denied.isEmpty)
        let bypassed = FreezePlanner.groups(bundleIds: ["com.docker.docker"], apps: apps, processes: processes, config: c, applyDenylist: false)
        XCTAssertEqual(bypassed.map(\.pids), [[400, 401]])
    }

    func testDenylistAgentListOverridesFreezeList() {
        var c = Config()
        c.agentList = ["com.tinyspeck.slackmacgap"]
        XCTAssertTrue(FreezePlanner.isDenied("com.tinyspeck.slackmacgap", config: c))
        XCTAssertTrue(FreezePlanner.groups(bundleIds: ["com.tinyspeck.slackmacgap"], apps: apps, processes: processes, config: c).isEmpty)

        c.agentList = []
        XCTAssertFalse(FreezePlanner.isDenied("com.tinyspeck.slackmacgap", config: c))
        XCTAssertEqual(FreezePlanner.groups(bundleIds: ["com.tinyspeck.slackmacgap"], apps: apps, processes: processes, config: c).count, 1)
    }

    func testDeniedIdsAreSkippedInMixedList() {
        let groups = FreezePlanner.groups(
            bundleIds: ["com.apple.Safari", Paths.bundleIdentifier, "com.docker.docker", "com.tinyspeck.slackmacgap"],
            apps: apps, processes: processes, config: Config()
        )
        XCTAssertEqual(groups.map(\.bundleId), ["com.tinyspeck.slackmacgap"])
    }

    func testDuplicateBundleIdsAndInstancesAreMergedOnce() {
        let two = apps + [RunningApp(pid: 500, bundleId: "com.tinyspeck.slackmacgap", name: "Slack")]
        let procs = processes + [ProcessEntry(pid: 500, ppid: 1), ProcessEntry(pid: 501, ppid: 500)]
        let groups = FreezePlanner.groups(bundleIds: ["com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap"], apps: two, processes: procs, config: Config())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].pids), [100, 101, 102, 103, 500, 501])
    }

    func testSuspendAndResumeSignalsGoToProcessControl() {
        let control = FakeProcessControl()
        let f = FakeFreezer(apps: apps, processes: processes, control: control)
        f.suspend(pids: [100, 101])
        f.resume(pids: [100, 101])
        XCTAssertEqual(control.suspended, [[100, 101]])
        XCTAssertEqual(control.resumed, [[100, 101]])
    }
}
