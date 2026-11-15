// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tuner",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TunerCore", targets: ["TunerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TunerCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .executableTarget(
            name: "Tuner",
            dependencies: ["TunerCore", "VLCKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TunerCoreTests",
            dependencies: ["TunerCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Command Line Tools without Xcode: the build intermittently fails to resolve the
                // Swift Testing macro plugin ("plugin for module 'TestingMacros' not found").
                // Naming its directory makes the lookup deterministic.
                .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"]),
            ]
        ),
    ]
)
