import XCTest
@testable import Insomnia

final class LaunchdBackstopTests: XCTestCase {
    func testPlistWithDeadlineHasCalendarIntervalOneMinuteLater() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let endsAt = cal.date(from: DateComponents(year: 2027, month: 3, day: 9, hour: 23, minute: 59))!
        let d = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", scriptPath: "/x/backstop.sh", endsAt: endsAt, calendar: cal)
        XCTAssertEqual(d["Label"] as? String, "com.insomnia.backstop")
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(d["ProgramArguments"] as? [String], ["/bin/bash", "/x/backstop.sh"])
        let sci = try XCTUnwrap(d["StartCalendarInterval"] as? [String: Int])
        XCTAssertEqual(sci, ["Minute": 0, "Hour": 0, "Day": 10, "Month": 3])
    }

    func testClearedPlistKeepsRunAtLoadOnly() {
        let d = LaunchdBackstop.plistDictionary(label: "l", scriptPath: "/x", endsAt: nil)
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertNil(d["StartCalendarInterval"])
    }

    func testWritePlistSerialises() throws {
        let home = TempHome()
        defer { home.destroy() }
        let b = LaunchdBackstop(paths: home.paths)
        try b.writePlist(endsAt: Date())
        let data = try Data(contentsOf: home.paths.backstopPlist)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(obj?["Label"] as? String, "com.insomnia.backstop")
        XCTAssertEqual((obj?["ProgramArguments"] as? [String])?.last, home.paths.backstopScript.path)
        try b.writePlist(endsAt: nil)
        let data2 = try Data(contentsOf: home.paths.backstopPlist)
        let obj2 = try PropertyListSerialization.propertyList(from: data2, format: nil) as? [String: Any]
        XCTAssertNil(obj2?["StartCalendarInterval"])
    }
}
