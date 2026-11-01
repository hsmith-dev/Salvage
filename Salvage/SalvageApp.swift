import SwiftUI

/// App entry point and composition root: later stories wire a concrete `SalvageDiskIO` adapter
/// into `SalvageCore` here, never inside a view. The only network code in the app lives in
/// `Updates/UpdateChecker.swift` and runs only from the explicit "Check for Updates…" action
/// (AD-12); nothing here starts a check on launch.
@main
struct SalvageApp: App {
    @State private var updates = UpdateChecker()
    @State private var scanActivity = ScanActivity()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(updates)
                .environment(scanActivity)
        }
        .commands {
            UpdateCommands(checker: updates, activity: scanActivity)
            OpenImageCommand()
        }
        .commands { ScanArchiveCommands() }

        Window("Check for Updates", id: UpdateWindow.id) {
            UpdateWindow()
                .environment(updates)
                .environment(scanActivity)
        }
        .windowResizability(.contentSize)
    }
}
