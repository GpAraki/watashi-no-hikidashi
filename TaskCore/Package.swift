// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TaskCore", targets: ["TaskCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TaskCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "TaskCoreTests",
            dependencies: ["TaskCore"]
        ),
    ]
)
