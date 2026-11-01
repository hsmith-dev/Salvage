import AppKit
import Foundation
import Testing

// App icon and branding (spec-tech-batch-7 §E): the built app carries the AppIcon from
// Salvage/Assets.xcassets, rendered from docs/brand/icon.svg by scripts/render-icon.sh. These run
// inside the hosted app, so Bundle.main is Salvage.app itself.

@Suite("App icon")
struct AppIconTests {
    @Test("Info.plist names the asset-catalog icon")
    func infoPlistNamesAppIcon() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["CFBundleIconName"] as? String == "AppIcon")
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    }

    // actool writes only the small sizes (16-128 pt) into the .icns fallback; the large ones
    // live in Assets.car, checked below.
    @Test("the compiled .icns fallback is in the bundle")
    func icnsIsBundled() throws {
        let url = try #require(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        let icon = try #require(NSImage(contentsOf: url))
        let widths = icon.representations.map(\.pixelsWide)
        #expect(widths.contains(16))
        #expect(widths.contains(32))
    }

    @Test("the asset catalog serves AppIcon at full size")
    func assetCatalogServesAppIcon() throws {
        let icon = try #require(NSImage(named: "AppIcon"))
        #expect(icon.representations.contains { $0.pixelsWide == 1024 })
    }
}
