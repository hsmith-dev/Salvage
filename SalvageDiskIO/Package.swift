// swift-tools-version: 6.0
import PackageDescription

// SalvageDiskIO -- the macOS adapter module of Salvage's hexagonal architecture (Architecture
// AD-1).
//
// Rule (AD-1): SalvageDiskIO depends only on SalvageCore (to conform to its ports). It is the
// exclusive owner of DiskArbitration -- no other module imports it. Enforced by
// `scripts/check-core-boundary.sh` in CI (AD-9).
let package = Package(
    name: "SalvageDiskIO",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SalvageDiskIO",
            targets: ["SalvageDiskIO"]
        )
    ],
    dependencies: [
        .package(path: "../SalvageCore")
    ],
    targets: [
        .target(
            name: "SalvageDiskIO",
            dependencies: ["SalvageCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("DiskArbitration")
            ]
        ),
        .testTarget(
            name: "SalvageDiskIOTests",
            dependencies: ["SalvageDiskIO"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
