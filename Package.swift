// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileShuffler",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Read-only XLSX parser. MIT-licensed, pure Swift.
        .package(url: "https://github.com/CoreOffice/CoreXLSX", from: "0.14.2"),
        // Apple's swift-testing — bundled with full Xcode but not Command Line
        // Tools, so we depend on it explicitly. Pin to a recent stable.
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "FileShuffler",
            dependencies: ["CoreXLSX"],
            path: "Sources/FileShuffler",
            // NetFS.framework backs `NetFSMounter`'s `NetFSMountURLSync`
            // call — needed to auto-mount the DimensionHub share when a
            // pasted path resolves under it but the volume isn't there.
            linkerSettings: [.linkedFramework("NetFS")]
        ),
        .testTarget(
            name: "FileShufflerTests",
            dependencies: [
                "FileShuffler",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/FileShufflerTests"
        )
    ]
)
