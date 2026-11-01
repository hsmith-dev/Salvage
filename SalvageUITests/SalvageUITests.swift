import AppKit
import XCTest

/// End-to-end UI tests (spec-tech-batch-5 §C). Each test launches the Debug app with
/// `-SalvageUITestFixture <name>` (`Salvage/Testing/UITestFixtures.swift`), so the Device Picker
/// lists only fixture drives, the scan reads a synthetic exFAT image held in memory, and recovery
/// writes only into a temporary folder this test creates and deletes. No real device is listed,
/// read or written, and nothing uses the network.
@MainActor
final class SalvageUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var destination: URL { workDirectory.appending(path: "Destination", directoryHint: .isDirectory) }
    private var expected: URL { workDirectory.appending(path: "Expected", directoryHint: .isDirectory) }

    /// The fixture image's files (`UITestFixture.files()`), by path.
    private let fixtureFiles = ["DCIM/IMG_0001.jpg", "DCIM/IMG_0002.png", "Documents/notes.txt",
                                "Documents/budget.csv", "readme.txt"]
    private let fixtureDriveID = "device-row-disk991"
    private let bootDriveID = "device-row-disk990"
    private let lockedDriveID = "device-row-disk992"

    override func setUp() async throws {
        continueAfterFailure = false
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SalvageUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    // MARK: (1) Device tree

    func testDeviceTreeShowsDisabledBootDriveAndFixtureDriveStartsScan() {
        launch("standard")
        let boot = element(bootDriveID)
        XCTAssertTrue(boot.waitForExistence(timeout: 10), "The boot drive is listed")
        XCTAssertTrue((boot.value as? String ?? "").contains("Your boot drive can't be scanned"),
                      "The boot drive states why it can't be scanned")
        XCTAssertTrue(boot.label.hasPrefix("Fixture Macintosh HD"), boot.label)
        let fixture = element(fixtureDriveID)
        XCTAssertTrue(fixture.label.hasPrefix("Salvage Fixture Drive"), fixture.label)
        let partition = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Partition FIXTURE, exFAT")).firstMatch
        XCTAssertTrue(partition.exists, "The fixture drive's partition is shown beneath it")

        // Clicking the boot drive is a no-op: no scan starts.
        boot.click()
        XCTAssertTrue(hasText("Select a device to start scanning.", timeout: 2))
        XCTAssertFalse(element("scan-title").exists)

        fixture.click()
        XCTAssertTrue(waitForScanCompleted(), "Selecting the fixture drive scans it to completion")
        XCTAssertTrue(element("results-status").label.contains("5 items found") ||
                      (element("results-status").value as? String ?? "").contains("5 items found"))
    }

    // MARK: (2) Progress, pause, resume, completion

    func testScanProgressPauseResumeAndCompletion() throws {
        launch("slowScan")
        element(fixtureDriveID).waitAndClick()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: pause, enabled: true, timeout: 10), "Pause is offered while the scan runs")
        XCTAssertTrue(hasText("Scanning…"))
        XCTAssertTrue(element("scan-progress-percent").exists, "Progress is shown")

        pause.click()
        XCTAssertTrue(hasText("Paused", timeout: 5))
        XCTAssertTrue(hasText(containing: "Scan paused. Salvage is not reading the device."))
        XCTAssertTrue(hasText("Remaining: Paused"))
        // Progress measured before Pause can still be in the event buffer under load and arrive
        // just after it (Core tests prove no read happens while paused). Let it settle, then
        // require the counter to stay frozen.
        var pausedAt = describe(element("scan-progress-percent"))
        let settleDeadline = Date().addingTimeInterval(15)
        while Date() < settleDeadline {
            Thread.sleep(forTimeInterval: 1)
            let now = describe(element("scan-progress-percent"))
            if now == pausedAt { break }
            pausedAt = now
        }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(describe(element("scan-progress-percent")), pausedAt, "No bytes are read while paused")
        XCTAssertFalse(hasText(containing: "Scan completed"))

        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.exists)
        resume.click()
        // The same scan carries on (it may already have finished on a fast machine).
        XCTAssertTrue(wait(timeout: 15) { self.hasText("Scanning…") || self.hasText(containing: "Scan completed") },
                      "Resume continues the same scan")
        XCTAssertFalse(hasText("Paused"))
        XCTAssertTrue(waitForScanCompleted(timeout: 90))
    }

    // MARK: (3) Dashboard, bucket, preview

    func testDashboardTilesAndPicturePreview() {
        launch("standard")
        element(fixtureDriveID).waitAndClick()
        XCTAssertTrue(waitForScanCompleted())

        let pictures = element("bucket-pictures")
        XCTAssertTrue(pictures.waitForExistence(timeout: 10))
        XCTAssertTrue(pictures.label.hasPrefix("Pictures, 2 files"), "Pictures tile: \(pictures.label)")
        XCTAssertTrue(element("bucket-documents").label.hasPrefix("Documents, 3 files"),
                      "Documents tile: \(element("bucket-documents").label)")
        XCTAssertTrue(element("bucket-videos").label.hasPrefix("Videos, 0 files"))
        XCTAssertTrue(hasText(containing: "5 files · "), "The total line counts every file")

        pictures.click()
        XCTAssertTrue(hasText(containing: "Pictures — 2 files", timeout: 10))
        let row = tableCell("IMG_0001.jpg")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(tableCell("notes.txt").exists, "The Pictures bucket lists only pictures")
        row.click()
        let preview = element("file-preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.contains("IMG_0001.jpg"), preview.label)
        XCTAssertFalse(hasText(containing: "No preview available", timeout: 2))
        // The rendered image is decorative (hidden from accessibility), so look at the pane itself:
        // the fixture picture is made of saturated color bands, which the empty pane never shows.
        XCTAssertTrue(wait(timeout: 10) { self.saturatedFraction(of: preview) > 0.05 }, "The picture is rendered")
    }

    // MARK: (4) Keyboard ticking, recover, byte-identical copies

    func testKeyboardSelectionRecoversByteIdenticalFiles() throws {
        launch("standard")
        element(fixtureDriveID).waitAndClick()
        XCTAssertTrue(waitForScanCompleted())
        app.buttons["Browse all files"].waitAndClick()
        XCTAssertTrue(hasText(containing: "All files — 5 files", timeout: 10))

        // Focus the table, tick everything with Cmd-A, then untick notes.txt with Return.
        tableCell("readme.txt").waitAndClick()
        app.typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(for: recover, labelContains: "Recover (5 selected)", timeout: 5), "Cmd-A ticks all: \(recover.label)")
        tableCell("notes.txt").click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(wait(for: recover, labelContains: "Recover (4 selected)", timeout: 5), "Return unticks: \(recover.label)")

        recover.click()
        XCTAssertTrue(hasText("Recover 4 files", timeout: 5))
        app.buttons["Choose…"].click()
        let confirm = element("recovery-confirm-button")
        XCTAssertTrue(wait(for: confirm, enabled: true, timeout: 10), "The fixture destination is safe")
        XCTAssertTrue(hasText(destination.path) || hasText(containing: destination.lastPathComponent))
        confirm.click()

        XCTAssertTrue(hasText("Recovery finished", timeout: 30))
        XCTAssertTrue(describe(element("recovery-summary-headline")).hasPrefix("Recovered 4 of 4 files"),
                      describe(element("recovery-summary-headline")))
        app.buttons["Done"].click()

        let roots = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        XCTAssertEqual(roots.count, 1, "One recovery folder")
        let root = try XCTUnwrap(roots.first)
        XCTAssertTrue(root.lastPathComponent.hasPrefix("Salvage Recovery Salvage Fixture Drive "), root.lastPathComponent)
        for path in fixtureFiles {
            let copy = root.appending(path: path, directoryHint: .notDirectory)
            if path == "Documents/notes.txt" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "An unticked file isn't recovered")
                continue
            }
            let original = try Data(contentsOf: expected.appending(path: path, directoryHint: .notDirectory))
            XCTAssertFalse(original.isEmpty)
            XCTAssertEqual(try Data(contentsOf: copy), original, "\(path) is byte-identical")
        }
    }

    // MARK: (5) Destination on the source drive

    func testDestinationOnSourceIsBlocked() {
        launch("destinationOnSource")
        element(fixtureDriveID).waitAndClick()
        XCTAssertTrue(waitForScanCompleted())
        app.buttons["Browse all files"].waitAndClick()
        tableCell("readme.txt").waitAndClick()
        app.typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(for: recover, labelContains: "Recover (5 selected)", timeout: 5))
        recover.click()
        app.buttons["Choose…"].waitAndClick()

        let banner = element("destination-blocked-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "The red block banner is shown")
        XCTAssertTrue(describe(banner).hasPrefix("Destination blocked. This folder is on the drive you're recovering from."),
                      describe(banner))
        XCTAssertFalse(element("recovery-confirm-button").isEnabled, "Recover is disabled")
        app.buttons["Cancel"].click()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [], "Nothing was written")
    }

    // MARK: (6) Trust Panel

    func testTrustPanelOpensWithItsStatement() {
        launch("standard")
        XCTAssertTrue(element(fixtureDriveID).waitForExistence(timeout: 10))
        app.buttons["What Salvage reads and writes"].firstMatch.click()
        // Each section reads as one element: its heading, then its text.
        XCTAssertTrue(hasText(containing: "What Salvage reads, Salvage reads only the drive you select.", timeout: 5))
        XCTAssertTrue(hasText(containing: "What Salvage writes, "))
        XCTAssertTrue(hasText(containing: "When Salvage uses the internet, "))
        XCTAssertTrue(hasText(containing: "No tracking, Salvage collects no usage data"))
        XCTAssertTrue(hasText(containing: "Salvage never writes anything to the drive it scans."))
        XCTAssertTrue(hasText(containing: "Salvage connects to the internet only when you choose Check for Updates."))
        // Never press Check for Updates here: that is the app's one network call.
        app.buttons["Done"].click()
        XCTAssertTrue(wait(timeout: 5) { !self.hasText(containing: "No tracking, ") }, "Done closes the panel")
    }

    // MARK: (7) FileVault unlock

    func testFileVaultSheetRejectsWrongPasswordThenUnlocks() {
        launch("fileVault")
        let locked = element(lockedDriveID)
        XCTAssertTrue(locked.waitForExistence(timeout: 10))
        XCTAssertTrue((locked.value as? String ?? "").hasPrefix("Locked"), "The locked drive says so")
        locked.click()

        XCTAssertTrue(hasText("Unlock \u{201C}Fixture Vault\u{201D}", timeout: 5))
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("wrong")
        app.buttons["Unlock"].click()
        XCTAssertTrue(app.descendants(matching: .any)["Unlock failed. Wrong password."].waitForExistence(timeout: 5)
                      || hasText(containing: "Wrong password.", timeout: 1),
                      "A wrong password is reported and the sheet stays open")
        XCTAssertFalse(element("scan-title").exists, "No scan starts on a wrong password")

        field.click()
        field.typeText("fixture-vault-pass")
        app.buttons["Unlock"].click()
        XCTAssertTrue(waitForScanCompleted(), "The correct password closes the sheet and scans the drive")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
    }

    // MARK: Helpers

    private func launch(_ fixture: String) {
        app = XCUIApplication()
        app.launchArguments = ["-SalvageUITestFixture", fixture,
                               "-SalvageUITestDestination", destination.path,
                               "-SalvageUITestExpected", expected.path,
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
    }

    /// SwiftUI may repeat an identifier when it merges a row's children ("id-id"), so a prefix
    /// match on "id-" is accepted too.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", identifier, identifier + "-"))
            .firstMatch
    }

    /// A static text whose label or value is exactly `string` (SwiftUI exposes some texts by
    /// label and others by value), polled for up to `timeout` seconds.
    private func hasText(_ string: String, timeout: TimeInterval = 0) -> Bool {
        let byLabel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", string)).firstMatch
        let byValue = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", string)).firstMatch
        return wait(timeout: timeout) { byLabel.exists || byValue.exists }
    }

    private func hasText(containing string: String, timeout: TimeInterval = 0) -> Bool {
        let byLabel = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", string)).firstMatch
        let byValue = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", string)).firstMatch
        return wait(timeout: timeout) { byLabel.exists || byValue.exists }
    }

    private func tableCell(_ name: String) -> XCUIElement {
        element("file-table").staticTexts.matching(NSPredicate(format: "value == %@", name)).firstMatch
    }

    /// The share of an element's on-screen pixels that are strongly colored.
    private func saturatedFraction(of element: XCUIElement) -> Double {
        guard element.exists,
              let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = NSBitmapImageRep(cgImage: image) as NSBitmapImageRep? else { return 0 }
        var saturated = 0, total = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if color.saturationComponent > 0.5 && color.brightnessComponent > 0.3 { saturated += 1 }
            }
        }
        return total == 0 ? 0 : Double(saturated) / Double(total)
    }

    private func describe(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    private func waitForScanCompleted(timeout: TimeInterval = 30) -> Bool {
        let status = element("results-status")
        return wait(timeout: timeout) { status.exists && self.describe(status).hasPrefix("Scan completed") }
    }

    private func wait(for element: XCUIElement, enabled: Bool, timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { element.exists && element.isEnabled == enabled }
    }

    private func wait(for element: XCUIElement, labelContains part: String, timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { element.exists && (element.label.contains(part) || self.describe(element).contains(part)) }
    }

    private func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }
}

private extension XCUIElement {
    @MainActor func waitAndClick(timeout: TimeInterval = 10) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(self) exists")
        click()
    }
}
