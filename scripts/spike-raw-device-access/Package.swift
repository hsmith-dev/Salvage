// swift-tools-version: 6.0
import PackageDescription

// spike-raw-device-access -- disposable CLI harness for Epic 1 Story 1.2's
// Full Disk Access / raw device access spike. NOT part of the shipping app, NOT wired into
// SalvageCore/SalvageDiskIO/Salvage -- a standalone SwiftPM executable per the spike's Design
// Notes ("a signed .app isn't required to test raw device access, only Full Disk Access
// matters"). See
// _bmad-output/implementation-artifacts/spec-1-2-full-disk-access-raw-device-access-spike.md.
let package = Package(
    name: "spike-raw-device-access",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "spike-raw-device-access",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("DiskArbitration")
            ]
        ),
        .testTarget(
            name: "spike-raw-device-accessTests",
            dependencies: ["spike-raw-device-access"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
