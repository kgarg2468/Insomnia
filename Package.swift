// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Insomnia",
    platforms: [
        .macOS(.v26),
    ],
    targets: [
        .executableTarget(
            name: "Insomnia",
            path: "Sources/Insomnia",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "InsomniaTests",
            dependencies: ["Insomnia"],
            path: "Tests/InsomniaTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
