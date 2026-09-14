import Foundation
import XCTest

final class PackagingTests: XCTestCase {
    func testAssemblerBundlesTheIconDeclaredByTheInfoPlist() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsomniaPackagingTests-\(UUID().uuidString)")
        let app = temporaryRoot.appendingPathComponent("Insomnia.app")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let process = Process()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/assemble-app.sh").path,
            app.path,
            "/usr/bin/true",
        ]
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()

        let errors = errorOutput.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: errors, as: UTF8.self)
        )
        guard process.terminationStatus == 0 else { return }

        let infoPlist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let metadata = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoPlist, format: nil)
                as? [String: Any]
        )
        let iconName = try XCTUnwrap(metadata["CFBundleIconFile"] as? String)
        XCTAssertEqual(iconName, "AppIcon")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: app.appendingPathComponent("Contents/Resources/\(iconName).icns").path
            )
        )
    }
}
