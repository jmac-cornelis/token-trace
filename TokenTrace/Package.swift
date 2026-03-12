// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TokenTrace",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "TokenTrace",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/TokenTrace"
        ),
        .testTarget(
            name: "TokenTraceTests",
            dependencies: [
                "TokenTrace",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/TokenTraceTests"
        ),
    ]
)
