import XCTest
@testable import Insomnia

final class StoreTests: XCTestCase {
    var home: TempHome!
    var store: Store!

    override func setUp() {
        home = TempHome()
        store = Store(paths: home.paths)
    }

    override func tearDown() {
        home.destroy()
    }

    func testMissingFileReturnsNil() throws {
        XCTAssertNil(try store.loadSession())
        XCTAssertNil(try store.loadState())
        XCTAssertNil(try store.loadConfig())
    }

    func testSessionRoundTrip() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600), extensions: [600, 1200])
        try store.saveSession(s)
        XCTAssertEqual(try store.loadSession(), s)
    }

    func testStateRoundTripPreservesOptionals() throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.frozenProcesses = [FrozenProcess(pid: 12, startedAt: 1_700_000_000), FrozenProcess(pid: 34, startedAt: 1_700_000_001)]
        st.savedOutputVolume = 0.6
        st.savedMuted = false
        try store.saveState(st)
        XCTAssertEqual(try store.loadState(), st)
    }

    /// backstop.sh reads the same file: each frozen process carries its
    /// kernel start time under the key the script looks for, and the legacy
    /// identity-less list is no longer written.
    func testStateWritesProcessIdentityForTheBackstop() throws {
        var st = RuntimeState()
        st.frozenProcesses = [FrozenProcess(pid: 12, startedAt: 1_700_000_000)]
        try store.saveState(st)
        let text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"frozenProcesses\""), text)
        XCTAssertTrue(text.contains("\"pid\" : 12"), text)
        XCTAssertTrue(text.contains("\"startedAt\" : 1700000000"), text)
        XCTAssertTrue(text.contains("\"startedAtMicros\" : 0"), text)
        XCTAssertTrue(text.contains("\"bootSession\" : \"boot\""), text)
        XCTAssertFalse(text.contains("frozenPids"), text)
    }

    /// A journal written by an older build lists bare pids. They decode as
    /// entries with no identity, which still count as dirty so the limitation
    /// is reported rather than silently dropped.
    func testLegacyFrozenPidsDecodeWithoutIdentity() throws {
        let data = Data(#"{"sleepDisabledByUs": false, "frozenPids": [12, 34]}"#.utf8)
        let st = try Store.makeDecoder().decode(RuntimeState.self, from: data)
        XCTAssertEqual(st.frozenProcesses, [FrozenProcess(pid: 12, startedAt: nil), FrozenProcess(pid: 34, startedAt: nil)])
        XCTAssertTrue(st.isDirty)
    }

    func testDatesAreISO8601ForBackstopScript() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveSession(Session(startedAt: t0, endsAt: t0))
        let text = try String(contentsOf: home.paths.sessionFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"endsAt\" : \"2027-01-15T08:00:00Z\""), text)
    }

    func testAtomicWriteLeavesNoTempFile() throws {
        try store.saveState(RuntimeState())
        try store.saveState(RuntimeState())
        let names = try FileManager.default.contentsOfDirectory(atPath: home.paths.appSupport.path)
        XCTAssertEqual(names.filter { $0.contains(".tmp-") }, [])
        XCTAssertTrue(names.contains("state.json"))
    }

    func testOverwriteReplacesContent() throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try store.saveState(st)
        try store.saveState(RuntimeState())
        XCTAssertEqual(try store.loadState(), RuntimeState())
    }

    func testRemoveMissingIsNotAnError() throws {
        XCTAssertNoThrow(try store.deleteSession())
    }

    func testStateDecodesWithMissingKeys() throws {
        let data = Data(#"{"sleepDisabledByUs": true}"#.utf8)
        let st = try Store.makeDecoder().decode(RuntimeState.self, from: data)
        XCTAssertTrue(st.sleepDisabledByUs)
        XCTAssertEqual(st.frozenProcesses, [])
        XCTAssertNil(st.savedOutputVolume)
    }

    func testPathsFromEnvironment() {
        let p = Paths.fromEnvironment(["INSOMNIA_HOME": "/tmp/x"])
        XCTAssertEqual(p.sessionFile.path, "/tmp/x/session.json")
        XCTAssertEqual(p.recoveryLock.path, "/tmp/x/.recovery.lock")
        XCTAssertEqual(p.logFile.path, "/tmp/x/Logs/insomnia.log")
        XCTAssertEqual(p.backstopPlist.path, "/tmp/x/LaunchAgents/com.insomnia.backstop.plist")
        let std = Paths.fromEnvironment([:])
        XCTAssertTrue(std.sessionFile.path.hasSuffix("/Library/Application Support/Insomnia/session.json"))
        XCTAssertTrue(std.backstopPlist.path.hasSuffix("/Library/LaunchAgents/com.insomnia.backstop.plist"))
    }

    /// A journal that does not decode is evidence of what a previous run
    /// changed. It is left exactly where it is, never moved or overwritten,
    /// and every later read keeps failing until a person deals with it: the
    /// next reader (this app, backstop.sh, uninstall.sh) must not see "no
    /// journal" and call the machine clean.
    func testCorruptStateIsLeftInPlaceAndKeepsFailing() throws {
        try Data("{not json".utf8).write(to: home.paths.stateFile)
        for _ in 0..<2 {
            XCTAssertThrowsError(try store.loadState()) { error in
                guard case StoreError.corrupt = error else { return XCTFail("\(error)") }
                XCTAssertTrue(error.localizedDescription.contains(home.paths.stateFile.path), error.localizedDescription)
            }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: home.paths.appSupport.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("state.json") }, ["state.json"], "\(names)")
        XCTAssertEqual(try String(contentsOf: home.paths.stateFile, encoding: .utf8), "{not json")
    }
}
