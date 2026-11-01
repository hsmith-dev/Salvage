import SwiftUI

/// DESIGN.md's ink tokens (ink-primary / ink-secondary / ink-tertiary) for text.
///
/// The system's `secondaryLabelColor` (3.95:1 on the light window background) and
/// `tertiaryLabelColor` (1.88:1 light, 2.26:1 dark) fall short of WCAG AA's 4.5:1, which the
/// accessibility audit reports on every screen (spec-tech-batch-6, Implementation Notes D). These
/// tokens keep the same black-or-white-at-an-alpha recipe as the system label colors, at alphas
/// that clear 4.5:1 on `windowBackgroundColor` and `controlBackgroundColor` in light and dark, and
/// step up again under Increase Contrast. The tonal steps stay distinct, and DESIGN.md's
/// confidence label still pairs them with size and weight; none of them is a hue.
///
/// Use for text only. Icons and other decorations keep the system hierarchical styles.
enum Ink: CaseIterable, Sendable {
    case primary, secondary, tertiary

    /// The token's alpha over black (light) or white (dark).
    func alpha(dark: Bool, increasedContrast: Bool) -> Double {
        switch (self, increasedContrast) {
        case (.primary, false): 0.85
        case (.primary, true): 1.0
        case (.secondary, false): 0.70
        case (.secondary, true): dark ? 0.82 : 0.80
        case (.tertiary, false): dark ? 0.55 : 0.58
        case (.tertiary, true): 0.68
        }
    }

    /// The token's color, as sRGB white level and alpha.
    func components(dark: Bool, increasedContrast: Bool) -> (white: Double, alpha: Double) {
        (dark ? 1 : 0, alpha(dark: dark, increasedContrast: increasedContrast))
    }

    fileprivate var systemStyle: HierarchicalShapeStyle {
        switch self {
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: .tertiary
        }
    }
}

/// A text style for one `Ink` token, resolved from the environment's appearance and contrast.
/// On an emphasized background (a selected list or table row) it defers to the system's
/// hierarchical style, which turns the text light against the selection highlight.
struct InkStyle: ShapeStyle {
    let ink: Ink

    static let primary = InkStyle(ink: .primary)
    static let secondary = InkStyle(ink: .secondary)
    static let tertiary = InkStyle(ink: .tertiary)

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        if environment.backgroundProminence == .increased { return AnyShapeStyle(ink.systemStyle) }
        let color = ink.components(dark: environment.colorScheme == .dark,
                                   increasedContrast: environment.colorSchemeContrast == .increased)
        return AnyShapeStyle(Color(.sRGB, white: color.white, opacity: color.alpha))
    }
}

extension ShapeStyle where Self == InkStyle {
    static var inkPrimary: InkStyle { .primary }
    static var inkSecondary: InkStyle { .secondary }
    static var inkTertiary: InkStyle { .tertiary }
}
