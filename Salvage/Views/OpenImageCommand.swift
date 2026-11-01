import SwiftUI

/// spec-tech-batch-7 §A: "File > Open Disk Image…" (⌘O). The chosen images are listed under
/// "Disk images" in the device list (`DiskImageLibrary`); nothing is read until one is selected.
struct OpenImageCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Disk Image…") { DiskImageLibrary.shared.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }
    }
}
