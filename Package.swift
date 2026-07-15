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
        // Already in the tree via CoreXLSX; declared directly so the
        // workbook-structure fallback in SpreadsheetReader can read the
        // sheet-name XML that CoreXLSX's strict relationship enum chokes
        // on (modern Excel adds relationship types it doesn't know).
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.11")),
        // Apple's swift-testing — bundled with full Xcode but not Command Line
        // Tools, so we depend on it explicitly. Pin to a recent stable.
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "FileShuffler",
            dependencies: ["CoreXLSX", "ZIPFoundation"],
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
                // Tests unzip the xlsx the sizes report writes to assert on
                // the worksheet XML inside.
                "ZIPFoundation",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/FileShufflerTests",
            // Dummy-data .xlsx mirroring the V1 job-sheet structure (banner
            // rows, header row 9, sparse cells, multiple worksheets).
            resources: [.copy("Fixtures")]
        )
    ]
)
