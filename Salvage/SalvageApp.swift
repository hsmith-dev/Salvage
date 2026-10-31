import SwiftUI

/// App entry point. This story's scope is a minimal shell only -- no recovery logic, disk I/O,
/// or network calls anywhere in this target (spec-1-1 Boundaries). `Salvage` is the composition
/// root: later stories wire a concrete `SalvageDiskIO` adapter into `SalvageCore` here, never
/// inside a view.
@main
struct SalvageApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
