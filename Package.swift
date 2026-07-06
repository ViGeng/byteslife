// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ByteLife",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ByteLifeCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ByteLifeApp",
            dependencies: ["ByteLifeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ByteLifeCoreTests",
            dependencies: ["ByteLifeCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
