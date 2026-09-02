import XCTest
@testable import Insomnia

final class SessionMathTests: XCTestCase {
    let maxDuration: TimeInterval = 30 * 24 * 3600
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testClampFloorAndCeiling() {
        XCTAssertEqual(SessionMath.clamp(0, maxDuration: maxDuration), SessionMath.minimumDuration)
        XCTAssertEqual(SessionMath.clamp(-5, maxDuration: maxDuration), SessionMath.minimumDuration)
        XCTAssertEqual(SessionMath.clamp(3600, maxDuration: maxDuration), 3600)
        XCTAssertEqual(SessionMath.clamp(maxDuration + 1, maxDuration: maxDuration), maxDuration)
        XCTAssertEqual(SessionMath.clamp(40 * 24 * 3600, maxDuration: maxDuration), maxDuration)
    }

    func testEndsAtUsesClampedDuration() {
        let end = SessionMath.endsAt(start: t0, duration: 100 * 24 * 3600, maxDuration: maxDuration)
        XCTAssertEqual(end, t0.addingTimeInterval(maxDuration))
    }

    func testExtendAddsToEndAndRecordsExtension() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600))
        let e = SessionMath.extended(s, by: 1800, now: t0.addingTimeInterval(600), maxDuration: maxDuration)
        XCTAssertEqual(e.endsAt, t0.addingTimeInterval(5400))
        XCTAssertEqual(e.extensions, [1800])
        XCTAssertEqual(e.startedAt, t0)
    }

    func testExtendIsClampedToMaxFromNow() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(29 * 24 * 3600))
        let now = t0.addingTimeInterval(3600)
        let e = SessionMath.extended(s, by: 5 * 24 * 3600, now: now, maxDuration: maxDuration)
        XCTAssertEqual(e.endsAt, now.addingTimeInterval(maxDuration))
    }

    func testExtendExpiredSessionRestartsFromNow() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(60))
        let now = t0.addingTimeInterval(3600)
        let e = SessionMath.extended(s, by: 600, now: now, maxDuration: maxDuration)
        XCTAssertEqual(e.endsAt, now.addingTimeInterval(600))
    }

    func testRemainingNeverNegative() {
        XCTAssertEqual(SessionMath.remaining(until: t0, at: t0.addingTimeInterval(10)), 0)
        XCTAssertEqual(SessionMath.remaining(until: t0.addingTimeInterval(90), at: t0), 90)
    }

    func testExpiryBoundary() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(60))
        XCTAssertFalse(s.isExpired(at: t0.addingTimeInterval(59.999)))
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(60)))
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(61)))
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(60)), 0)
    }

    func testFormatFourShapes() {
        XCTAssertEqual(SessionMath.formatRemaining(3 * 86400 + 2 * 3600 + 5 * 60), "3d 2h")
        XCTAssertEqual(SessionMath.formatRemaining(2 * 3600 + 14 * 60 + 59), "2h 14m")
        XCTAssertEqual(SessionMath.formatRemaining(14 * 60 + 1), "14m")
        XCTAssertEqual(SessionMath.formatRemaining(59), "<1m")
        XCTAssertEqual(SessionMath.formatRemaining(0), "<1m")
        XCTAssertEqual(SessionMath.formatRemaining(-5), "<1m")
    }

    func testFormatDropsZeroSecondaryUnits() {
        XCTAssertEqual(SessionMath.formatRemaining(2 * 3600), "2h")
        XCTAssertEqual(SessionMath.formatRemaining(3 * 86400), "3d")
        XCTAssertEqual(SessionMath.formatRemaining(60), "1m")
    }

    func testNextMinuteBoundary() {
        let d = Date(timeIntervalSinceReferenceDate: 1234.5)
        XCTAssertEqual(SessionMath.nextMinuteBoundary(after: d).timeIntervalSinceReferenceDate, 1260)
        let exact = Date(timeIntervalSinceReferenceDate: 1260)
        XCTAssertEqual(SessionMath.nextMinuteBoundary(after: exact).timeIntervalSinceReferenceDate, 1320)
    }
}
