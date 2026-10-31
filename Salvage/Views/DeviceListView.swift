import SalvageCore
import SalvageDiskIO
import SwiftUI

/// EXPERIENCE.md Voice and Tone: "Your boot drive can't be scanned while macOS is running from
/// it." -- the exact copy specified for the boot-volume row's stated reason. Shared at file scope
/// so both `DeviceRow`'s visual text and `DeviceListView`'s accessibility value (applied after
/// `.disabled(...)`, so it reaches VoiceOver regardless of how a disabled row is announced) use
/// the identical string.
private let bootVolumeReason = "Your boot drive can't be scanned while macOS is running from it."

/// Plain-language copy for the anomalous "watcher delivered, but not even the startup disk" state.
enum DeviceListCopy {
    static let noDrivesTitle = "No drives found."
    static let noDrivesDetail = "Salvage couldn't see any drives, not even your startup disk. Try quitting and reopening Salvage."
}

// `@MainActor`-isolated: `ByteCountFormatter` is a non-`Sendable` mutable class, but every call
// site below is a SwiftUI view body, which is itself `@MainActor`-isolated, so this cached
// formatter is never touched off the main actor.
@MainActor
private let deviceSizeFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
}()

@MainActor
private func sizeText(for device: BlockDevice) -> String {
    deviceSizeFormatter.string(fromByteCount: device.sizeBytes)
}

/// The Device Picker (FR-1) -- the entry point to every recovery session. One row per whole-disk
/// `BlockDevice`; the boot volume is always shown, grayed, with its one-line reason, never
/// omitted; internal and external devices render together in a single unified list, never split
/// into sections. Clicking an eligible row validates selection and starts a scan through the composition root. See `DESIGN.md`'s `device-row` component and `EXPERIENCE.md`'s
/// Device row / State Patterns for the full behavioral spec this view implements.
struct DeviceListView: View {
    @State private var viewModel = DeviceListViewModel()
    var isScanning = false
    var activeDeviceID: BlockDevice.ID?
    var onSelect: (BlockDevice) -> Void = { _ in }

    var body: some View {
        content
            .task { viewModel.startWatching() }
            .onDisappear { viewModel.stopWatching() }
            .onChange(of: isScanning) { _, active in if !active { viewModel.clearSelection() } }
    }

    @ViewBuilder
    private var content: some View {
        if let watchError = viewModel.watchError {
            // Distinguished from the merely-empty state below: on a running Mac, the boot volume
            // should always enumerate, so an error here is a genuine anomaly, not an expected
            // "nothing attached yet" moment. The icon (single-weight, `.secondary` -- never
            // colored, per DESIGN.md's no-color-for-non-blocking-errors rule) is the only visual
            // difference; copy stays plain-language throughout and never names an internal
            // mechanism like "DiskArbitration" (EXPERIENCE.md Voice and Tone).
            StatusMessage(
                title: "Couldn't list storage devices.",
                detail: watchError.description,
                icon: "exclamationmark.triangle"
            )
        } else if !viewModel.hasReceivedDevices {
            // Neutral loading state for the brief window between `.task` starting the watch and
            // its first emission landing, so that window never flashes "No storage devices
            // found." -- which would be misleading on every single launch, since the boot volume
            // always enumerates once the first emission arrives.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.seesNoDrives {
            // The startup disk always enumerates on a running Mac, so a delivered-but-empty list
            // is anomalous -- never the reassuring "connect a drive" copy.
            StatusMessage(
                title: DeviceListCopy.noDrivesTitle,
                detail: DeviceListCopy.noDrivesDetail,
                icon: "exclamationmark.triangle"
            )
        } else {
            deviceList
        }
    }

    private var deviceList: some View {
        List(selection: selectionBinding) {
            ForEach(viewModel.devices) { device in
                DeviceRow(device: device, inUse: isScanning && activeDeviceID == device.id)
                    .tag(device.id)
                    .disabled(device.isBootVolume || isScanning)
                    // Re-applied explicitly after `.disabled(...)` (rather than relying solely on
                    // `DeviceRow`'s own internal accessibility) so the boot-volume reason reaches
                    // VoiceOver even if a disabled row's announcement behavior turns out to be
                    // inconsistent -- not confirmed either way, no VoiceOver testing was done.
                    .accessibilityLabel(device.displayName)
                    .accessibilityValue(device.isBootVolume ? bootVolumeReason : (isScanning && activeDeviceID == device.id ? "In use by another scan" : sizeText(for: device)))
            }
        }
        .listStyle(.inset)
    }

    /// Routes List's own selection mechanism through `DeviceListViewModel`: a non-nil id goes
    /// through `selectDevice(_:)` (which re-derives boot status from the canonical `devices`
    /// entry, never trusting whatever is passed in -- see that method); `nil` (the user clicking
    /// empty list space or pressing Escape) clears the selection via `clearSelection()`, since
    /// without this case a device could never be deselected once chosen.
    private var selectionBinding: Binding<BlockDevice.ID?> {
        Binding(
            get: { viewModel.selectedDeviceID },
            set: { newID in
                guard let newID else {
                    viewModel.clearSelection()
                    return
                }
                guard let device = viewModel.devices.first(where: { $0.id == newID }) else { return }
                guard !isScanning else { return }
                viewModel.selectDevice(device)
                if viewModel.selectedDeviceID == device.id { onSelect(device) }
            }
        )
    }
}

/// One device row -- `DESIGN.md`'s `device-row` component (surface-raised background,
/// `rounded/sm` corners, `spacing/3` padding). Purely visual: `DeviceListView.deviceList` applies
/// the row's accessibility label/value itself (after `.disabled(...)`), so this view's own text
/// and that accessibility content can't drift out of sync without also being visually obvious.
private struct DeviceRow: View {
    let device: BlockDevice
    var inUse = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.isInternal ? "internaldrive" : "externaldrive")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                    .foregroundStyle(device.isBootVolume ? .secondary : .primary)

                if device.isBootVolume {
                    Text(bootVolumeReason)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(inUse ? "In use by another scan" : sizeText(for: device))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(device.isBootVolume ? 0.6 : 1.0)
    }
}

/// Shared layout for the Device Picker's non-list, non-loading states (the anomalous "no drives
/// at all" state and the watcher error state) -- plain, factual, no illustration/animation
/// (EXPERIENCE.md's State Patterns), with an optional single-weight icon (see
/// `DeviceListView.content`).
private struct StatusMessage: View {
    let title: String
    let detail: String
    var icon: String?

    var body: some View {
        VStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    DeviceListView()
        .frame(width: 480, height: 320)
}
