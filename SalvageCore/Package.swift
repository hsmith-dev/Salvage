// swift-tools-version: 6.0
import PackageDescription

// SalvageCore -- the domain module of Salvage's hexagonal architecture (Architecture AD-1).
//
// Rule (AD-1): SalvageCore depends on nothing but Foundation. No AppKit, SwiftUI, IOKit, or
// DiskArbitration import is permitted anywhere in this package's source tree -- enforced by
// `scripts/check-core-boundary.sh` in CI (AD-9), not just by this manifest having zero package
// dependencies.
let package = Package(
    name: "SalvageCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SalvageCore",
            targets: ["SalvageCore"]
        )
    ],
    targets: [
        .target(
            name: "SalvageCore",
            // AD-6: carving signatures are data, shipped as a copied resource directory.
            resources: [.copy("Carving/Signatures")],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SalvageCoreTests",
            dependencies: ["SalvageCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
