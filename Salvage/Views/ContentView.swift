import SwiftUI

/// The app's initial shell: a blank window, nothing more. Intentionally has no recovery
/// features, device list, or disk I/O -- those land in later Epic 1 stories (1.3+). Makes zero
/// network calls, satisfying FR-17/FR-18 from the very first build.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Salvage")
                .font(.title)
            Text("Project foundation scaffold -- no recovery features yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding()
    }
}

#Preview {
    ContentView()
}
