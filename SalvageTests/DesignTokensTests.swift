import AppKit
import Testing
@testable import Salvage

// DESIGN.md ink tokens (DesignTokens.swift): every text step meets WCAG 2.x AA (4.5:1) against the
// system's real window and content backgrounds, resolved in light and dark, with and without
// Increase Contrast, and the three steps stay distinct (confidence is size + weight + tone).

@Suite("Ink token contrast")
struct DesignTokensTests {
    struct Appearance: CustomTestStringConvertible, Sendable {
        let name: NSAppearance.Name
        let dark: Bool
        var testDescription: String { dark ? "dark" : "light" }
    }

    static let appearances = [Appearance(name: .aqua, dark: false), Appearance(name: .darkAqua, dark: true)]

    /// The sRGB components of a system color as resolved in `appearance`.
    static func resolved(_ color: NSColor, in appearance: Appearance) throws -> (r: Double, g: Double, b: Double) {
        let nsAppearance = try #require(NSAppearance(named: appearance.name))
        var rgb: (Double, Double, Double)?
        nsAppearance.performAsCurrentDrawingAppearance {
            if let srgb = color.usingColorSpace(.sRGB) {
                rgb = (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
            }
        }
        let value = try #require(rgb)
        return (value.0, value.1, value.2)
    }

    static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG contrast ratio of `ink` composited over `background`.
    static func ratio(_ ink: Ink, over background: NSColor, in appearance: Appearance,
                      increasedContrast: Bool) throws -> Double {
        let bg = try resolved(background, in: appearance)
        let fg = ink.components(dark: appearance.dark, increasedContrast: increasedContrast)
        func over(_ b: Double) -> Double { fg.white * fg.alpha + b * (1 - fg.alpha) }
        let l1 = luminance((over(bg.r), over(bg.g), over(bg.b)))
        let l2 = luminance(bg)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test("each ink token is at least 4.5:1 on the window and content backgrounds",
          arguments: appearances, [false, true])
    func meetsAA(appearance: Appearance, increasedContrast: Bool) throws {
        for background in [NSColor.windowBackgroundColor, .controlBackgroundColor] {
            for ink in Ink.allCases {
                let value = try Self.ratio(ink, over: background, in: appearance, increasedContrast: increasedContrast)
                #expect(value >= 4.5, "\(ink) on \(background) (\(appearance.testDescription), increased contrast \(increasedContrast)): \(value)")
            }
        }
    }

    @Test("the steps stay distinct: primary > secondary > tertiary by a clear margin",
          arguments: appearances, [false, true])
    func keepsHierarchy(appearance: Appearance, increasedContrast: Bool) throws {
        let ratios = try Ink.allCases.map {
            try Self.ratio($0, over: .windowBackgroundColor, in: appearance, increasedContrast: increasedContrast)
        }
        #expect(ratios[0] > ratios[1] * 1.3)
        #expect(ratios[1] > ratios[2] * 1.3)
    }

    @Test("Increase Contrast never lowers a token", arguments: appearances)
    func increaseContrastRaises(appearance: Appearance) {
        for ink in Ink.allCases {
            #expect(ink.alpha(dark: appearance.dark, increasedContrast: true)
                    >= ink.alpha(dark: appearance.dark, increasedContrast: false))
        }
    }

    @Test("tokens are neutral grays, never a hue", arguments: appearances, [false, true])
    func neutral(appearance: Appearance, increasedContrast: Bool) {
        for ink in Ink.allCases {
            #expect([0, 1].contains(ink.components(dark: appearance.dark, increasedContrast: increasedContrast).white))
        }
    }
}
