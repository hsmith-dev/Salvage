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

/// The Device Picker (FR-1) -- the entry point to every recovery session. One selectable row per
/// whole-disk `BlockDevice`, with its partitions and volumes nested beneath it (informational); the boot volume is always shown, grayed, with its one-line reason, never
/// omitted; internal and external devices render together in a single unified list, never split
/// into sections. Clicking an eligible row validates selection and starts a scan through the composition root. See `DESIGN.md`'s `device-row` component and `EXPERIENCE.md`'s
/// Device row / State Patterns for the full behavioral spec this view implements.
struct DeviceListView: View {
    @State private var viewModel = DeviceListViewModel(watcher: CompositionRoot.deviceWatcher())
    /// Tree nodes the user expanded or collapsed away from their default
    /// (`DeviceTreeNode.startsExpanded`).
    @State private var toggledNodeIDs: Set<String> = []
    /// spec-tech-batch-7 §A: disk images opened from the File menu or dropped on the list.
    @State private var images = DiskImageLibrary.shared
    @State private var selectedImageID: String?
    var isScanning = false
    var activeDeviceID: BlockDevice.ID?
    /// The drive whose scan has finished with results open; its partition rows offer
    /// "Recover all files…" in their context menu.
    var finishedScanDevice: BlockDevice?
    var onRecoverPartition: (DevicePartition) -> Void = { _ in }
    var onSelect: (BlockDevice) -> Void = { _ in }

    var body: some View {
        content
            .task { viewModel.startWatching() }
            .onChange(of: finishedScanDevice, initial: true) { _, device in viewModel.finishedScanDevice = device }
            .onDisappear { viewModel.stopWatching() }
            .onChange(of: isScanning) { _, active in if !active { viewModel.clearSelection() } }
            .onChange(of: isScanning) { _, active in if !active { selectedImageID = nil } }
            .dropDestination(for: URL.self) { urls, _ in images.open(urls); return !urls.isEmpty }
            #if DEBUG
            .task { images.openUITestImageIfRequested() }
            #endif
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

    /// The Disk Utility-style tree: each drive is a top-level row, its partitions, APFS
    /// containers and volumes indented beneath it, expanded by default. Only drive rows are
    /// selectable (and selecting one starts a scan, as before); partition rows are information.
    /// Recursive `DisclosureGroup`s rather than `OutlineGroup`/`List(children:)`, which open
    /// collapsed with no way to start expanded.
    private var deviceList: some View {
        List(selection: selectionBinding) {
            ForEach(viewModel.tree.filter { !images.hiddenDrives.contains($0.id) }) { node in
                if case .drive(let device) = node.kind {
                    if node.children.isEmpty {
                        driveRow(device)
                    } else {
                        DisclosureGroup(isExpanded: expansion(of: node, toggled: $toggledNodeIDs)) {
                            ForEach(node.children) { child in
                                PartitionTreeRows(node: child, toggled: $toggledNodeIDs, recoverAction: recoverAction)
                            }
                        } label: {
                            driveRow(device)
                        }
                    }
                }
            }
            diskImagesSection
        }
        .listStyle(.inset)
    }

    /// The context-menu action for a partition row, or nil when it offers none.
    private func recoverAction(for partition: DevicePartition) -> (() -> Void)? {
        guard let target = viewModel.recoverAllTarget(for: partition) else { return nil }
        return { onRecoverPartition(target) }
    }

    private func driveRow(_ device: BlockDevice) -> some View {
        DeviceRow(device: device, inUse: isScanning && activeDeviceID == device.id)
            .tag(device.id)
            .disabled(device.isBootVolume || isScanning)
            .selectionDisabled(device.isBootVolume || isScanning)
            // Re-applied explicitly after `.disabled(...)` (rather than relying solely on
            // `DeviceRow`'s own internal accessibility) so the boot-volume reason reaches
            // VoiceOver even if a disabled row's announcement behavior turns out to be
            // inconsistent -- not confirmed either way, no VoiceOver testing was done.
            .accessibilityLabel(device.displayName)
            .accessibilityValue(accessibilityValue(for: device))
            .accessibilityIdentifier("device-row-\(device.id)")
    }

    /// The glyph alone never conveys the FileVault state (EXPERIENCE.md): "Locked" is spoken too.
    private func accessibilityValue(for device: BlockDevice) -> String {
        if device.isBootVolume { return bootVolumeReason }
        if isScanning && activeDeviceID == device.id { return "In use by another scan" }
        guard device.encryptedVolumeUUID != nil else { return sizeText(for: device) }
        let locked = "Locked, \(sizeText(for: device))"
        return UnlockViewModel.pickerNote(for: device).map { "\(locked). \($0)" } ?? locked
    }

    /// Routes List's own selection mechanism through `DeviceListViewModel`: a non-nil id goes
    /// through `selectDevice(_:)` (which re-derives boot status from the canonical `devices`
    /// entry, never trusting whatever is passed in -- see that method); `nil` (the user clicking
    /// empty list space or pressing Escape) clears the selection via `clearSelection()`, since
    /// without this case a device could never be deselected once chosen.
    private var selectionBinding: Binding<BlockDevice.ID?> {
        Binding(
            get: { viewModel.selectedDeviceID ?? selectedImageID },
            set: { newID in
                guard let newID else {
                    viewModel.clearSelection()
                    selectedImageID = nil
                    return
                }
                if let image = images.image(withDeviceID: newID) {
                    guard !isScanning else { return }
                    viewModel.clearSelection()
                    selectedImageID = image.id
                    onSelect(image.device)
                    return
                }
                selectedImageID = nil
                // Only drive rows are scan targets: a partition's id is never in `devices`.
                guard let device = viewModel.devices.first(where: { $0.id == newID }) else { return }
                guard !isScanning else { return }
                viewModel.selectDevice(device)
                if viewModel.selectedDeviceID == device.id { onSelect(device) }
            }
        )
    }
}

// MARK: - Disk images (spec-tech-batch-7 §A)

extension DeviceListView {
    /// Opened disk images, each scanned like a drive (and only ever read). Remove takes one off the
    /// list; it is offered except while that image is being scanned.
    @ViewBuilder
    fileprivate var diskImagesSection: some View {
        if !images.images.isEmpty || images.openError != nil {
            Section("Disk images") {
                ForEach(images.images) { image in
                    let inUse = isScanning && activeDeviceID == image.id
                    DiskImageRow(image: image, inUse: inUse)
                        .tag(image.id)
                        .disabled(isScanning)
                        .selectionDisabled(isScanning)
                        .contextMenu {
                            Button("Remove from List") { images.remove(image.id) }
                                .disabled(inUse)
                        }
                        .accessibilityLabel(image.name)
                        .accessibilityValue(inUse ? "In use by another scan" : "Disk image, \(deviceSizeFormatter.string(fromByteCount: image.sizeBytes))")
                        .accessibilityIdentifier("image-row-\(image.name)")
                }
                if let error = images.openError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                        .accessibilityIdentifier("image-open-error")
                }
            }
        }
    }
}

/// A disk image row: the file's name and size, styled like a drive row.
private struct DiskImageRow: View {
    let image: OpenedDiskImage
    var inUse = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(inUse ? "In use by another scan" : deviceSizeFormatter.string(fromByteCount: image.sizeBytes))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(image.url.path)
    }
}

/// One device row -- `DESIGN.md`'s `device-row` component (surface-raised background,
/// `rounded/sm` corners, `spacing/3` padding). Purely visual: `DeviceListView.deviceList` applies
/// the row's accessibility label/value itself (after `.disabled(...)`), so this view's own text
/// and that accessibility content can't drift out of sync without also being visually obvious.
private struct DeviceRow: View {
    let device: BlockDevice
    var inUse = false
    private var isLocked: Bool { device.encryptedVolumeUUID != nil }

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
                    Text(inUse ? "In use by another scan" : (isLocked ? "\(sizeText(for: device)) · Locked" : sizeText(for: device)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Story 2.4: while the unlock sheet is withheld, say plainly what happens.
                    if !inUse, let note = UnlockViewModel.pickerNote(for: device) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer()

            // Story 2.4: a FileVault-locked device (EXPERIENCE.md "FileVault locked (known up
            // front)"). Decorative here; `DeviceListView` speaks "Locked" in the row's value.
            if isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(device.isBootVolume ? 0.6 : 1.0)
    }
}

/// A node's expansion: its default (`startsExpanded`), flipped if the user toggled it.
private func expansion(of node: DeviceTreeNode, toggled: Binding<Set<String>>) -> Binding<Bool> {
    Binding(
        get: { node.startsExpanded != toggled.wrappedValue.contains(node.id) },
        set: { expanded in
            if expanded == node.startsExpanded { toggled.wrappedValue.remove(node.id) } else { toggled.wrappedValue.insert(node.id) }
        }
    )
}

/// A partition, APFS container or volume row, with its own children beneath it (expanded by
/// default, see `DeviceTreeNode.startsExpanded`). Never selectable: secondary text, no selection tag that matches a drive.
private struct PartitionTreeRows: View {
    let node: DeviceTreeNode
    @Binding var toggled: Set<String>
    var recoverAction: (DevicePartition) -> (() -> Void)? = { _ in nil }

    var body: some View {
        if node.children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: expansion(of: node, toggled: $toggled)) {
                ForEach(node.children) { child in
                    PartitionTreeRows(node: child, toggled: $toggled, recoverAction: recoverAction)
                }
            } label: {
                row
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        if case .partition(let partition, let drive, let container) = node.kind {
            PartitionRow(partition: partition)
                .selectionDisabled()
                // Still informational; once this drive's scan has finished it can be recovered whole.
                .contextMenu {
                    if let action = recoverAction(partition) { Button("Recover all files…", action: action) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DeviceListViewModel.accessibilityLabel(for: partition, drive: drive,
                                                                           container: container))
        }
    }
}

/// One partition/volume row: name, format and size, in secondary text.
private struct PartitionRow: View {
    let partition: DevicePartition

    var body: some View {
        HStack(spacing: 8) {
            Text(partition.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }

    private var detail: String {
        guard let size = partition.sizeBytes else { return partition.formatName }
        return "\(partition.formatName) · \(deviceSizeFormatter.string(fromByteCount: size))"
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
