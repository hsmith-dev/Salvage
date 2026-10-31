import SalvageCore
import SwiftUI

/// Recovery confidence as text only (DESIGN.md confidence-label): size, weight and tone change
/// together so the step is perceivable without color. nil means the file can't be recovered.
struct ConfidenceLabel: View {
    let confidence: RecoveryConfidence?
    var body: some View {
        Group {
            switch confidence {
            case .high: Text("High").font(.body).fontWeight(.semibold).foregroundStyle(.primary)
            case .medium: Text("Medium").font(.subheadline).foregroundStyle(.secondary)
            case .low: Text("Low").font(.caption).foregroundStyle(.tertiary)
            case nil: Text("Can't be recovered").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    var accessibilityText: String {
        confidence.map { "Recovery confidence \($0.displayName)" } ?? "Can't be recovered"
    }
}
