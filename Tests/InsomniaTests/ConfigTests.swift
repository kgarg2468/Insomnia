import XCTest
@testable import Insomnia

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = Config()
        XCTAssertEqual(c.presets, [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200])
        XCTAssertEqual(c.lowPowerFloor, 40)
        XCTAssertEqual(c.endFloor, 10)
        XCTAssertEqual(c.nudgeThreshold, 90)
        XCTAssertEqual(c.maxDuration, 30 * 24 * 3600)
        XCTAssertEqual(c.freezeList, ["com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.hnc.Discord"])
        XCTAssertTrue(c.agentList.contains("com.apple.Terminal"))
        XCTAssertTrue(c.agentList.contains("com.t3tools.t3code"))
        XCTAssertTrue(c.agentList.contains("com.docker.docker"))
        XCTAssertTrue(c.dockerRule)
        XCTAssertFalse(c.muteOnLidClose)
        XCTAssertTrue(c.thermalRules)
        XCTAssertEqual(c.hotspotSSID, "")
        XCTAssertEqual(c.tmuxTargets, [])
        XCTAssertFalse(c.launchAtLogin)
    }

    func testPartialJSONFillsDefaults() throws {
        let data = Data(#"{"lowPowerFloor": 25}"#.utf8)
        let c = try Store.makeDecoder().decode(Config.self, from: data)
        var expected = Config()
        expected.lowPowerFloor = 25
        XCTAssertEqual(c, expected)
    }

    func testEmptyObjectIsDefaults() throws {
        let c = try Store.makeDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(c, Config())
    }

    func testRoundTrip() throws {
        var c = Config()
        c.hotspotSSID = "iPhone"
        c.tmuxTargets = ["main:0.1"]
        c.presets = [60]
        let data = try Store.makeEncoder().encode(c)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), c)
    }
}
