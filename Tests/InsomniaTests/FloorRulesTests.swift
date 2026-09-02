import XCTest
@testable import Insomnia

final class FloorRulesTests: XCTestCase {
    func eval(_ percent: Int?, charging: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, lp: Bool = false, config: Config = Config()) -> [FloorRules.Action] {
        FloorRules.evaluate(percent: percent, isCharging: charging, thermal: thermal, lowPowerSetByUs: lp, config: config)
    }

    // Row 1: battery below lowPowerFloor -> lowpowermode 1
    func testBelowLowPowerFloorEnablesLowPower() {
        XCTAssertEqual(eval(39), [.enableLowPower])
        XCTAssertEqual(eval(40), [])
        XCTAssertEqual(eval(39, lp: true), [])
    }

    // Row 1 undo: charger connected, or session end (session end is restoreAll)
    func testChargerConnectedClearsLowPower() {
        XCTAssertEqual(eval(39, charging: true, lp: true), [.disableLowPower])
        XCTAssertEqual(eval(39, charging: true), [])
    }

    func testBackAboveFloorClearsLowPower() {
        XCTAssertEqual(eval(45, lp: true), [.disableLowPower])
    }

    // Row 2: battery below endFloor -> end session
    func testBelowEndFloorEndsSession() {
        XCTAssertEqual(eval(9), [.endSession(.batteryFloor)])
        XCTAssertEqual(eval(10), [.enableLowPower])
        XCTAssertEqual(eval(9, lp: true), [.endSession(.batteryFloor)])
    }

    func testBelowEndFloorWhileChargingDoesNotEnd() {
        XCTAssertEqual(eval(5, charging: true), [])
    }

    // Row 3: thermal serious -> lowpowermode 1; undo when nominal/fair
    func testThermalSeriousEnablesLowPower() {
        XCTAssertEqual(eval(80, thermal: .serious), [.enableLowPower])
        XCTAssertEqual(eval(80, charging: true, thermal: .serious), [.enableLowPower])
        XCTAssertEqual(eval(80, thermal: .serious, lp: true), [])
    }

    func testThermalBackToNominalOrFairClearsLowPower() {
        XCTAssertEqual(eval(80, thermal: .nominal, lp: true), [.disableLowPower])
        XCTAssertEqual(eval(80, thermal: .fair, lp: true), [.disableLowPower])
    }

    // Row 4: thermal critical -> end session
    func testThermalCriticalEndsSession() {
        XCTAssertEqual(eval(80, thermal: .critical), [.endSession(.thermalCritical)])
        XCTAssertEqual(eval(nil, thermal: .critical), [.endSession(.thermalCritical)])
    }

    func testBatteryEndFloorWinsOverThermalCritical() {
        XCTAssertEqual(eval(5, thermal: .critical), [.endSession(.batteryFloor)])
    }

    func testThermalRulesOffIgnoresThermal() {
        var c = Config()
        c.thermalRules = false
        XCTAssertEqual(eval(80, thermal: .serious, config: c), [])
        XCTAssertEqual(eval(80, thermal: .critical, config: c), [])
        XCTAssertEqual(eval(80, thermal: .serious, lp: true, config: c), [.disableLowPower])
        // Battery rules still apply.
        XCTAssertEqual(eval(30, thermal: .critical, config: c), [.enableLowPower])
    }

    func testLowPowerStaysWhileEitherCauseHolds() {
        XCTAssertEqual(eval(30, thermal: .serious, lp: true), [])
        XCTAssertEqual(eval(30, thermal: .nominal, lp: true), [])
        XCTAssertEqual(eval(80, charging: true, thermal: .serious, lp: true), [])
    }

    func testNoBatteryInfoOnlyThermalApplies() {
        XCTAssertEqual(eval(nil), [])
        XCTAssertEqual(eval(nil, thermal: .serious), [.enableLowPower])
    }

    func testCustomFloors() {
        var c = Config()
        c.lowPowerFloor = 60
        c.endFloor = 25
        XCTAssertEqual(eval(59, config: c), [.enableLowPower])
        XCTAssertEqual(eval(24, config: c), [.endSession(.batteryFloor)])
    }
}

@MainActor
final class FloorRuleDriverTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    func testLowPowerIsJournaledBeforePmsetAndNotified() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "lowpowermode 1"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode on")
        XCTAssertTrue(h.notifier.posts.last?.body.contains("35%") ?? false)

        await driver.run(percent: 35, isCharging: true, thermal: .nominal)
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 0")
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode off")
    }

    func testLowPowerFailureRollsBackJournal() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["lowpowermode 1"]
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == "Low Power Mode on" })
    }

    func testEndFloorEndsSessionWithReason() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 8, isCharging: false, thermal: .nominal)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        XCTAssertEqual(h.notifier.posts.last?.title, "Session ended")
        XCTAssertTrue(h.notifier.posts.last?.body.contains("10%") ?? false)
    }

    func testThermalCriticalEndsSession() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        await m.setLowPower(true)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 80, isCharging: false, thermal: .critical)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"))
        XCTAssertTrue(h.notifier.posts.last?.body.contains("critical") ?? false)
    }

    func testNoSessionDoesNothing() async throws {
        let m = h.makeManager()
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 5, isCharging: false, thermal: .critical)
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertEqual(h.notifier.posts.count, 0)
    }
}
