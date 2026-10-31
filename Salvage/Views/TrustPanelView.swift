import SwiftUI

/// The Trust Panel (FR-19): a plain-language statement of what Salvage reads, what it writes, and
/// when it uses the network. The statement scrolls independently of the title and Done button,
/// so it is never clipped at large text sizes (EXPERIENCE.md Accessibility Floor).
struct TrustPanelView: View {
    var isScanning = false
    var onDone: () -> Void = {}
    @Environment(UpdateChecker.self) private var checker: UpdateChecker?

    static let sourceCodeURL = URL(string: "https://github.com/hsmith-dev/Salvage")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What Salvage reads and writes")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TrustSection(title: "What Salvage reads", text: TrustPanelCopy.reads)
                    TrustSection(title: "What Salvage writes", text: TrustPanelCopy.writes)
                    TrustSection(title: "When Salvage uses the internet", text: TrustPanelCopy.network)
                    updateControls
                    TrustSection(title: "No tracking", text: TrustPanelCopy.telemetry)
                    TrustSection(title: "After a scan", text: TrustPanelCopy.afterScan)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Check it yourself").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(TrustPanelCopy.sourceCode).fixedSize(horizontal: false, vertical: true)
                        Link("View the source code on GitHub", destination: Self.sourceCodeURL)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 460, idealWidth: 540, maxWidth: 720, minHeight: 320, idealHeight: 560)
    }

    @ViewBuilder
    private var updateControls: some View {
        if let checker {
            VStack(alignment: .leading, spacing: 8) {
                Button("Check for Updates…") { Task { await checker.check() } }
                    .disabled(isScanning || checker.isChecking)
                if isScanning {
                    Text("Checking for updates is unavailable while a scan is running.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    UpdateCheckStatus(checker: checker).font(.callout)
                }
            }
        }
    }
}

enum TrustPanelCopy {
    static let reads = "Salvage reads only the drive you select. Before it scans, it unmounts that drive so nothing else can change it, then reads it in read-only mode. It doesn't look at your other drives, and it can't scan your startup drive while macOS is running from it."
    static let writes = "Salvage never writes anything to the drive it scans. When you recover files, it saves copies only to a folder you choose, and nowhere else. A scan on its own saves nothing."
    static let network = "Salvage connects to the internet only when you choose Check for Updates. It then asks GitHub for the version number of the newest Salvage release. That request contains nothing about you, your Mac, or your drives, though like any website GitHub can see your internet address. Salvage never downloads or installs anything. If a newer version exists, it can open the release page in your web browser. It never checks on its own, and Check for Updates is unavailable while a scan is running."
    static let telemetry = "Salvage collects no usage data, analytics, or crash reports, and there is no account to sign in to."
    static let afterScan = "The drive stays unmounted after a scan. To use it in Finder again, disconnect it and plug it back in."
    static let sourceCode = "Salvage is open source, so anyone can read the code behind every statement on this page."
}

private struct TrustSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Presents the Trust Panel and reports this window's scan state to the app-wide `ScanActivity`,
/// which keeps "Check for Updates…" disabled in the app menu while any scan is running.
struct TrustPanelPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let isScanning: Bool
    @Environment(ScanActivity.self) private var activity: ScanActivity?
    @State private var windowToken = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isScanning, initial: true) { _, scanning in activity?.set(windowToken, active: scanning) }
            .onDisappear { activity?.set(windowToken, active: false) }
            .sheet(isPresented: $isPresented) {
                TrustPanelView(isScanning: isScanning) { isPresented = false }
            }
    }
}

extension View {
    func trustPanel(isPresented: Binding<Bool>, isScanning: Bool) -> some View {
        modifier(TrustPanelPresenter(isPresented: isPresented, isScanning: isScanning))
    }
}

#Preview { TrustPanelView() }
