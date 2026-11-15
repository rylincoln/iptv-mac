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
            ]
        ),
    ]
)
