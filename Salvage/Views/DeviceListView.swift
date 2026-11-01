import SalvageCore
import SalvageDiskIO
import SwiftUI

/// Plain-language copy for the anomalous "watcher delivered, but not even the startup disk" state.
enum DeviceListCopy {
    static let noDrivesTitle = "No drives found."
    static let noDrivesDetail = "Salvage couldn't see any drives, not even your startup disk. Try quitting and reopening Salvage."
    /// Everything attached is under "Hidden" (on most Macs: just the startup disk).
    static let nothingToScan = "Connect a drive or open a disk image to get started."
}

/// Sidebar section titles, as Disk Utility names them.
enum DeviceListSection {
    static let internalDrives = "Internal"
    static let externalDrives = "External"
    static let diskImages = "Disk Images"
    static let hidden = "Hidden"
    /// Remembers, per viewer, whether "Hidden" is open. It starts collapsed.
    static let hiddenExpandedKey = "DeviceList.hiddenExpanded"
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

/// The Device Picker (FR-1) -- the entry point to every recovery session -- laid out like Disk
/// Utility's sidebar: "Internal", "External" and "Disk Images" sections, one selectable row per
/// whole device (the scan target), with its partitions, APFS containers and volumes indented
/// beneath it (information only). What can't or needn't be scanned -- the startup disk, disk
/// images macOS attached for itself -- sits in a collapsed "Hidden" group at the bottom, each with
/// its one-line reason, never omitted. Clicking an eligible device row starts a scan through the
/// composition root. See `DESIGN.md`'s `device-row` component and `EXPERIENCE.md`'s Device row /
/// State Patterns.
struct DeviceListView: View {
    @State private var viewModel: DeviceListViewModel
    /// Tree nodes the user expanded or collapsed away from their default
    /// (`DeviceTreeNode.startsExpanded`).
    @State private var toggledNodeIDs: Set<String> = []
    /// spec-tech-batch-7 §A: disk images opened from the File menu or dropped on the list.
    @State private var images: DiskImageLibrary
    @State private var selectedImageID: String?
    @AppStorage(DeviceListSection.hiddenExpandedKey) private var hiddenExpanded = false
    var isScanning = false
    var activeDeviceID: BlockDevice.ID?
    /// The drive whose scan has finished with results open; its partition rows offer
    /// "Recover all files…" in their context menu.
    var finishedScanDevice: BlockDevice?
    var onRecoverPartition: (DevicePartition) -> Void = { _ in }
    /// spec-tech-image-drive: "Image This Drive…" in a drive row's context menu.
    var onImageDrive: (BlockDevice) -> Void = { _ in }
    var onSelect: (BlockDevice) -> Void = { _ in }

    init(watcher: any DeviceWatching = CompositionRoot.deviceWatcher(), images: DiskImageLibrary = .shared,
         isScanning: Bool = false, activeDeviceID: BlockDevice.ID? = nil, finishedScanDevice: BlockDevice? = nil,
         onRecoverPartition: @escaping (DevicePartition) -> Void = { _ in },
         onImageDrive: @escaping (BlockDevice) -> Void = { _ in },
         onSelect: @escaping (BlockDevice) -> Void = { _ in }) {
        _viewModel = State(initialValue: DeviceListViewModel(watcher: watcher))
        _images = State(initialValue: images)
        self.isScanning = isScanning
        self.activeDeviceID = activeDeviceID
        self.finishedScanDevice = finishedScanDevice
        self.onRecoverPartition = onRecoverPartition
        self.onImageDrive = onImageDrive
        self.onSelect = onSelect
    }

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

    /// The Disk Utility-style sidebar. Only device rows are selectable (and selecting one starts a
    /// scan); partition rows are information. A `DisclosureGroup` per device rather than
    /// `OutlineGroup`/`List(children:)`, which open collapsed with no way to start expanded.
    private var deviceList: some View {
        let sidebar = viewModel.sidebar(excluding: images.hiddenDrives)
        return List(selection: selectionBinding) {
            if !sidebar.internalDrives.isEmpty {
                Section(DeviceListSection.internalDrives) { driveTrees(sidebar.internalDrives) }
            }
            if !sidebar.externalDrives.isEmpty {
                Section(DeviceListSection.externalDrives) { driveTrees(sidebar.externalDrives) }
            }
            if sidebar.hasNoVisibleDrives && images.images.isEmpty && images.openError == nil {
                Text(DeviceListCopy.nothingToScan)
                    .font(.subheadline)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectionDisabled()
                    .accessibilityIdentifier("no-scannable-drives")
            }
            diskImagesSection(attached: sidebar.diskImages)
            if !sidebar.hidden.isEmpty { hiddenSection(sidebar.hidden) }
        }
        .listStyle(.inset)
        .accessibilityLabel("Devices")
    }

    /// Each device as a top-level row, its partition tree indented beneath it.
    @ViewBuilder
    private func driveTrees(_ nodes: [DeviceTreeNode]) -> some View {
        ForEach(nodes) { node in
            if case .drive(let device) = node.kind {
                if node.children.isEmpty {
                    driveRow(device)
                } else {
                    DisclosureGroup(isExpanded: expansion(of: node, toggled: $toggledNodeIDs)) {
                        PartitionTreeRows(nodes: node.children, toggled: $toggledNodeIDs, recoverAction: recoverAction)
                    } label: {
                        driveRow(device)
                    }
                }
            }
        }
    }

    /// The context-menu action for a partition row, or nil when it offers none.
    private func recoverAction(for partition: DevicePartition) -> (() -> Void)? {
        guard let target = viewModel.recoverAllTarget(for: partition) else { return nil }
        return { onRecoverPartition(target) }
    }

    private func driveRow(_ device: BlockDevice) -> some View {
        DeviceRow(device: device, inUse: isScanning && activeDeviceID == device.id)
            .listRowSeparator(.hidden)
            .tag(device.id)
            .disabled(device.isBootVolume || isScanning)
            .selectionDisabled(device.isBootVolume || isScanning)
            // Re-applied explicitly after `.disabled(...)` (rather than relying solely on
            // `DeviceRow`'s own internal accessibility) so the row's state reaches VoiceOver even
            // if a disabled row's announcement behavior turns out to be inconsistent.
            .accessibilityLabel(device.displayName)
            .accessibilityValue(accessibilityValue(for: device))
            .accessibilityIdentifier("device-row-\(device.id)")
            .contextMenu { imageDriveButton(device) }
    }

    private func imageDriveButton(_ device: BlockDevice) -> some View {
        Button("Image This Drive…") { onImageDrive(device) }
            .disabled(!DriveImagingCenter.canImage(device) || (isScanning && activeDeviceID == device.id))
            .accessibilityIdentifier("image-drive-menu-\(device.id)")
    }

    /// The glyph alone never conveys the FileVault state (EXPERIENCE.md): "Locked" is spoken too.
    private func accessibilityValue(for device: BlockDevice) -> String {
        if device.isBootVolume { return HiddenDeviceReason.startupDisk.text }
        if isScanning && activeDeviceID == device.id { return "In use by another scan" }
        let kind = device.isDiskImage ? "Disk image, " : ""
        guard device.encryptedVolumeUUID != nil else { return kind + sizeText(for: device) }
        let locked = "\(kind)Locked, \(sizeText(for: device))"
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
                // Only device rows are scan targets: a partition's id is never in `devices`.
                guard let device = viewModel.devices.first(where: { $0.id == newID }) else { return }
                guard !isScanning else { return }
                viewModel.selectDevice(device)
                if viewModel.selectedDeviceID == device.id { onSelect(device) }
            }
        )
    }
}

// MARK: - Disk images (spec-tech-batch-7 §A) and Hidden

extension DeviceListView {
    /// Disk images the user attached (each a device with its partition tree), then the image files
    /// opened in Salvage, each scanned like a drive (and only ever read). Remove takes an opened
    /// file off the list; it is offered except while that image is being scanned.
    @ViewBuilder
    fileprivate func diskImagesSection(attached: [DeviceTreeNode]) -> some View {
        if !attached.isEmpty || !images.images.isEmpty || images.openError != nil {
            Section(DeviceListSection.diskImages) {
                driveTrees(attached)
                ForEach(images.images) { image in
                    let inUse = isScanning && activeDeviceID == image.id
                    DiskImageRow(image: image, inUse: inUse)
                        .listRowSeparator(.hidden)
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
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                        .accessibilityIdentifier("image-open-error")
                }
            }
        }
    }

    /// The collapsed "Hidden" group: the startup disk (never selectable) and macOS's own disk
    /// images (selectable, as any image), each with its reason. Its open state is remembered.
    fileprivate func hiddenSection(_ hidden: [HiddenDevice]) -> some View {
        Section {
            DisclosureGroup(isExpanded: $hiddenExpanded) {
                ForEach(hidden) { item in
                    let selectable = item.reason.isScannable && !isScanning
                    HiddenDeviceRow(item: item, inUse: isScanning && activeDeviceID == item.id)
                        .listRowSeparator(.hidden)
                        .tag(item.id)
                        .disabled(!selectable)
                        .selectionDisabled(!selectable)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.title)
                        .accessibilityValue("\(item.reason.text). \(sizeText(for: item.device))")
                        .accessibilityIdentifier("device-row-\(item.id)")
                        .contextMenu { if item.reason.isScannable { imageDriveButton(item.device) } }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(DeviceListSection.hidden)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.inkSecondary)
                    Text("\(hidden.count)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.inkTertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hidden, \(hidden.count) \(hidden.count == 1 ? "device" : "devices")")
                .accessibilityHint("Devices Salvage can't scan, and disk images macOS uses for itself")
            }
            .selectionDisabled()
            .accessibilityIdentifier("hidden-group")
        }
    }
}

/// The device row's first line, as Disk Utility titles a device: "MK3252GSX — 320.07 GB". One
/// run of text, so a long name wraps onto a second line instead of hiding the capacity.
private struct DeviceTitle: View {
    let name: String
    let size: String

    var body: some View {
        (Text(name).font(.headline).foregroundStyle(.inkPrimary)
            + Text(capacitySuffix(size)).font(.headline.weight(.regular)).foregroundStyle(.inkSecondary))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A disk image file opened in Salvage: its name and size, styled like a device row.
private struct DiskImageRow: View {
    let image: OpenedDiskImage
    var inUse = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.title3)
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                DeviceTitle(name: image.name, size: deviceSizeFormatter.string(fromByteCount: image.sizeBytes))
                Text(inUse ? "In use by another scan" : "Image file · opened in Salvage")
                    .font(.subheadline)
                    .foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(image.url.path)
    }
}

/// One device row -- `DESIGN.md`'s `device-row` component (surface-raised background,
/// `rounded/sm` corners, `spacing/3` padding): the drive's icon, "Model — capacity", and what it
/// holds. It is the scan target; its partitions are the plain rows indented beneath it. Purely
/// visual: `DeviceListView` applies the row's accessibility label/value itself.
private struct DeviceRow: View {
    let device: BlockDevice
    var inUse = false
    private var isLocked: Bool { device.encryptedVolumeUUID != nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: deviceSymbol(device))
                .font(.title3)
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                DeviceTitle(name: device.displayName, size: sizeText(for: device))
                Text(inUse ? "In use by another scan" : (isLocked ? "\(contents) · Locked" : contents))
                    .font(.subheadline)
                    .foregroundStyle(.inkSecondary)
                // Story 2.4: while the unlock sheet is withheld, say plainly what happens.
                if !inUse, let note = UnlockViewModel.pickerNote(for: device) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

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
        .help(device.diskImagePath ?? "")
    }

    /// "Whole drive · 2 partitions": says this row is the device, and what is beneath it.
    private var contents: String {
        let kind = device.isDiskImage ? "Disk image" : "Whole drive"
        let count = device.partitions.count
        guard count > 0 else { return kind }
        return "\(kind) · \(count) \(count == 1 ? "partition" : "partitions")"
    }
}

/// A row in "Hidden": the device's icon and title, and why it is here. Flat (no partition tree):
/// these are listed so nothing is silently omitted, not to be browsed.
private struct HiddenDeviceRow: View {
    let item: HiddenDevice
    var inUse = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: deviceSymbol(item.device))
                .frame(width: 22)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                (Text(item.title).foregroundStyle(.inkSecondary)
                    + Text(capacitySuffix(sizeText(for: item.device))).foregroundStyle(.inkTertiary))
                    .font(.subheadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(inUse ? "In use by another scan" : item.reason.text)
                    .font(.caption)
                    .foregroundStyle(.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .help(item.device.diskImagePath ?? item.device.displayName)
    }
}

/// " — 320.07 GB", with non-breaking spaces after the dash and inside the size, so a name too
/// long for one line wraps before the dash and the capacity stays whole.
private func capacitySuffix(_ size: String) -> String {
    " —\u{00A0}" + size.replacingOccurrences(of: " ", with: "\u{00A0}")
}

private func deviceSymbol(_ device: BlockDevice) -> String {
    if device.isDiskImage { return "doc" }
    return device.isInternal ? "internaldrive" : "externaldrive"
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

/// A drive's partitions and APFS containers, each container's volumes beneath it, as plain
/// (never selectable) rows. Flat list rows indented by hand rather than nested
/// `DisclosureGroup`s, whose outline indentation is too slight to tell a volume from its
/// container; a container opens and closes with its own chevron (expanded by default, see
/// `DeviceTreeNode.startsExpanded`).
private struct PartitionTreeRows: View {
    let nodes: [DeviceTreeNode]
    @Binding var toggled: Set<String>
    var recoverAction: (DevicePartition) -> (() -> Void)? = { _ in nil }

    var body: some View {
        ForEach(nodes) { node in
            let expanded = expansion(of: node, toggled: $toggled)
            row(node, depth: 0, expanded: node.children.isEmpty ? nil : expanded)
            if !node.children.isEmpty && expanded.wrappedValue {
                ForEach(node.children) { child in row(child, depth: 1, expanded: nil) }
            }
        }
    }

    @ViewBuilder
    private func row(_ node: DeviceTreeNode, depth: Int, expanded: Binding<Bool>?) -> some View {
        if case .partition(let partition, let drive, let container) = node.kind {
            PartitionRow(partition: partition, depth: depth, expanded: expanded)
                .listRowSeparator(.hidden)
                .selectionDisabled()
                // Still informational; once this drive's scan has finished it can be recovered whole.
                .contextMenu {
                    if let action = recoverAction(partition) { Button("Recover all files…", action: action) }
                }
                .accessibilityElement(children: .ignore)
                // Information, not a control: without a trait the merged element has no role.
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(DeviceListViewModel.accessibilityLabel(for: partition, drive: drive,
                                                                           container: container))
                .accessibilityValue(expanded.map { $0.wrappedValue ? "Expanded" : "Collapsed" } ?? "")
                .modifier(ToggleAction(expanded: expanded))
        }
    }
}

/// VoiceOver's way to open or close a container (the chevron itself is merged into the row).
private struct ToggleAction: ViewModifier {
    let expanded: Binding<Bool>?

    func body(content: Content) -> some View {
        if let expanded {
            content.accessibilityAction(named: expanded.wrappedValue ? "Collapse" : "Expand") { expanded.wrappedValue.toggle() }
        } else {
            content
        }
    }
}

/// One partition/volume row: the name, then format and size, in secondary text. Indented so a
/// drive's partitions line up under the drive's name and a container's volumes sit one step in.
private struct PartitionRow: View {
    let partition: DevicePartition
    var depth = 0
    /// A container's open state; nil for a row with nothing beneath it.
    var expanded: Binding<Bool>?

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Color.clear
                if let expanded {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(expanded.wrappedValue ? "Hide volumes" : "Show volumes")
                }
            }
            .frame(width: 12)
            Text(partition.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail)
                .monospacedDigit()
                .foregroundStyle(.inkTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.subheadline)
        .foregroundStyle(.inkSecondary)
        .padding(.vertical, 2)
        .padding(.leading, 16 + CGFloat(depth) * 16)
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
                .foregroundStyle(.inkSecondary)
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
