import XCTest
@testable import Insomnia

final class PmsetParsingTests: XCTestCase {
    let withFlag = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     SleepDisabled        1
     hibernatefile        /var/vm/sleepimage
     powernap             0
     lidwake              1
     disksleep            10
     sleep                1 (sleep prevented by powerd, coreaudiod)
     displaysleep         10
    """

    let withoutFlag = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             0
     lidwake              1
     disksleep            10
     sleep                1
     displaysleep         10
    """

    let zeroFlag = """
    Currently in use:
     SleepDisabled        0
     sleep                1
    """

    func testDetectsSleepDisabledOne() {
        XCTAssertTrue(PmsetSleepGuard.parseSleepDisabled(withFlag))
    }

    func testAbsentFlagIsFalse() {
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(withoutFlag))
    }

    func testZeroFlagIsFalse() {
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(zeroFlag))
    }

    func testEmptyOutputIsFalse() {
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(""))
    }

    func testDoesNotMatchSubstringsOfOtherKeys() {
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(" SleepDisabledFoo 1\n"))
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(" sleep 1\n"))
    }

    func testTabSeparated() {
        XCTAssertTrue(PmsetSleepGuard.parseSleepDisabled("SleepDisabled\t1\n"))
    }

    func testErrorMessageMentionsInstall() {
        let e = SleepGuardError(command: "sudo -n pmset -a disablesleep 1", status: 1, stderr: "sudo: a password is required\n")
        let msg = e.errorDescription ?? ""
        XCTAssertTrue(msg.contains("disablesleep 1"))
        XCTAssertTrue(msg.contains("password is required"))
        XCTAssertTrue(msg.contains("install.sh"))
    }
}
