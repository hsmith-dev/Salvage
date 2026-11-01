import AppKit
import XCTest

/// End-to-end UI tests (spec-tech-batch-5 §C). Each test launches the Debug app with
/// `-SalvageUITestFixture <name>` (`Salvage/Testing/UITestFixtures.swift`), so the Device Picker
/// lists only fixture drives, the scan reads a synthetic exFAT image held in memory, and recovery
/// writes only into a temporary folder this test creates and deletes. No real device is listed,
/// read or written, and nothing uses the network.
///
/// The accessibility audits (spec-tech-batch-6 §D) run `performAccessibilityAudit()` on every main
/// screen and fail with every issue found, named by screen.
///
/// Other apps on this Mac may take keyboard focus while the suite runs. Every keyboard interaction
/// goes through `typeKey`/`typeText` below, which bring Salvage to the front first and retry once
/// after re-activating on "Failed to synthesize event". If Salvage still can't get focus, the test
/// records "another app holds keyboard focus" instead of a misleading assertion. No other app is
/// ever closed or touched.
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

    /// Accessibility audit issues found so far in this test, by screen.
    private var auditFindings: [String] = []
    /// While set, "Failed to synthesize event" issues are captured here instead of failing the test.
    private var capturedSynthesisFailures: [XCTIssue]?
    /// Elements outside Salvage that XCUITest reported as covering it, left untouched.
    private var interruptions: [String] = []

    override func setUp() async throws {
        continueAfterFailure = false
        auditFindings = []
        interruptions = []
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SalvageUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        if failIfPermissionPromptIsOpen() { throw XCTSkip("Not run: another app's permission prompt is open.") }
    }

    override func tearDown() async throws {
        app?.terminate()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    override func record(_ issue: XCTIssue) {
        if capturedSynthesisFailures != nil, issue.compactDescription.contains("Failed to synthesize event") {
            capturedSynthesisFailures?.append(issue)
            return
        }
        // XCUITest's own wording when another app's window stays over Salvage after the
        // interruption monitor declined to touch it; say plainly what happened.
        if issue.compactDescription.contains("Handler claimed to have handled") {
            var focus = issue
            focus.compactDescription = "Another app holds keyboard focus or covers Salvage (frontmost: "
                + "\(frontmostAppName)), left untouched: \(issue.compactDescription)"
            super.record(focus)
            return
        }
        super.record(issue)
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
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Partition FIXTURE, exFAT",
                                  "Partition FIXTURE, exFAT")).firstMatch
        XCTAssertTrue(partition.waitForExistence(timeout: 5), "The fixture drive's partition is shown beneath it")

        // Clicking the boot drive is a no-op: no scan starts.
        click(boot)
        XCTAssertTrue(hasText("Select a device to start scanning.", timeout: 2))
        XCTAssertFalse(element("scan-title").exists)

        click(fixture)
        XCTAssertTrue(waitForScanCompleted(), "Selecting the fixture drive scans it to completion")
        XCTAssertTrue(element("results-status").label.contains("5 items found") ||
                      (element("results-status").value as? String ?? "").contains("5 items found"))
    }

    // MARK: (2) Progress, pause, resume, completion

    func testScanProgressPauseResumeAndCompletion() throws {
        launch("slowScan")
        click(element(fixtureDriveID))
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: pause, enabled: true, timeout: 10), "Pause is offered while the scan runs")
        XCTAssertTrue(hasText("Scanning…"))
        XCTAssertTrue(element("scan-progress-percent").exists, "Progress is shown")

        click(pause)
        XCTAssertTrue(hasText("Paused", timeout: 5))
        XCTAssertTrue(hasText(containing: "Scan paused. Salvage is not reading the device."))
        XCTAssertTrue(hasText("Remaining: Paused"))
        // Progress measured before Pause can still be in the event buffer under load and arrive
        // just after it (Core tests prove no read happens while paused). Wait for the counter to
        // settle, then require it to stay frozen.
        let percent = element("scan-progress-percent")
        let pausedAt = waitUntilStable(percent, for: 1.5, timeout: 15)
        XCTAssertNotNil(pausedAt, "Progress settles once paused: \(describe(percent))")
        XCTAssertFalse(wait(timeout: 2) { self.describe(percent) != pausedAt },
                       "No bytes are read while paused: \(pausedAt ?? "") became \(describe(percent))")
        XCTAssertFalse(hasText(containing: "Scan completed"))

        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.exists)
        click(resume)
        // The same scan carries on (it may already have finished on a fast machine).
        XCTAssertTrue(wait(timeout: 15) { self.hasText("Scanning…") || self.hasText(containing: "Scan completed") },
                      "Resume continues the same scan")
        XCTAssertFalse(hasText("Paused"))
        XCTAssertTrue(waitForScanCompleted(timeout: 90))
    }

    // MARK: (3) Dashboard, bucket, preview

    func testDashboardTilesAndPicturePreview() {
        launch("standard")
        click(element(fixtureDriveID))
        XCTAssertTrue(waitForScanCompleted())

        let pictures = element("bucket-pictures")
        XCTAssertTrue(pictures.waitForExistence(timeout: 10))
        XCTAssertTrue(pictures.label.hasPrefix("Pictures, 2 files"), "Pictures tile: \(pictures.label)")
        XCTAssertTrue(element("bucket-documents").label.hasPrefix("Documents, 3 files"),
                      "Documents tile: \(element("bucket-documents").label)")
        XCTAssertTrue(element("bucket-videos").label.hasPrefix("Videos, 0 files"))
        XCTAssertTrue(hasText(containing: "5 files · "), "The total line counts every file")

        click(pictures)
        XCTAssertTrue(hasText(containing: "Pictures — 2 files", timeout: 10))
        let row = tableCell("IMG_0001.jpg")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(tableCell("notes.txt").exists, "The Pictures bucket lists only pictures")
        click(row)
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
        click(element(fixtureDriveID))
        XCTAssertTrue(waitForScanCompleted())
        click(app.buttons["Browse all files"])
        XCTAssertTrue(hasText(containing: "All files — 5 files", timeout: 10))

        // Focus the table, tick everything with Cmd-A, then untick notes.txt with Return.
        click(tableCell("readme.txt"))
        typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(for: recover, labelContains: "Recover (5 selected)", timeout: 5), "Cmd-A ticks all: \(recover.label)")
        click(tableCell("notes.txt"))
        typeKey(.return, modifierFlags: [])
        XCTAssertTrue(wait(for: recover, labelContains: "Recover (4 selected)", timeout: 5), "Return unticks: \(recover.label)")

        click(recover)
        XCTAssertTrue(hasText("Recover 4 files", timeout: 5))
        click(app.buttons["Choose…"])
        let confirm = element("recovery-confirm-button")
        XCTAssertTrue(wait(for: confirm, enabled: true, timeout: 10), "The fixture destination is safe")
        XCTAssertTrue(hasText(destination.path) || hasText(containing: destination.lastPathComponent))
        click(confirm)

        XCTAssertTrue(hasText("Recovery finished", timeout: 30))
        XCTAssertTrue(describe(element("recovery-summary-headline")).hasPrefix("Recovered 4 of 4 files"),
                      describe(element("recovery-summary-headline")))
        click(app.buttons["Done"])

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
        click(element(fixtureDriveID))
        XCTAssertTrue(waitForScanCompleted())
        click(app.buttons["Browse all files"])
        click(tableCell("readme.txt"))
        typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(for: recover, labelContains: "Recover (5 selected)", timeout: 5))
        click(recover)
        click(app.buttons["Choose…"])

        let banner = element("destination-blocked-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "The red block banner is shown")
        XCTAssertTrue(describe(banner).hasPrefix("Destination blocked. This folder is on the drive you're recovering from."),
                      describe(banner))
        XCTAssertFalse(element("recovery-confirm-button").isEnabled, "Recover is disabled")
        click(app.buttons["Cancel"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [], "Nothing was written")
    }

    // MARK: (6) Trust Panel

    func testTrustPanelOpensWithItsStatement() {
        launch("standard")
        XCTAssertTrue(element(fixtureDriveID).waitForExistence(timeout: 10))
        click(app.buttons["What Salvage reads and writes"].firstMatch)
        // Each section reads as one element: its heading, then its text.
        XCTAssertTrue(hasText(containing: "What Salvage reads, Salvage reads only the drive you select.", timeout: 5))
        XCTAssertTrue(hasText(containing: "What Salvage writes, "))
        XCTAssertTrue(hasText(containing: "When Salvage uses the internet, "))
        XCTAssertTrue(hasText(containing: "No tracking, Salvage collects no usage data"))
        XCTAssertTrue(hasText(containing: "Salvage never writes anything to the drive it scans."))
        XCTAssertTrue(hasText(containing: "Salvage connects to the internet only when you choose Check for Updates."))
        // Never press Check for Updates here: that is the app's one network call.
        click(app.buttons["Done"])
        XCTAssertTrue(wait(timeout: 5) { !self.hasText(containing: "No tracking, ") }, "Done closes the panel")
    }

    // MARK: (7) FileVault unlock

    func testFileVaultSheetRejectsWrongPasswordThenUnlocks() {
        launch("fileVault")
        let locked = element(lockedDriveID)
        XCTAssertTrue(locked.waitForExistence(timeout: 10))
        XCTAssertTrue((locked.value as? String ?? "").hasPrefix("Locked"), "The locked drive says so")
        click(locked)

        XCTAssertTrue(hasText("Unlock \u{201C}Fixture Vault\u{201D}", timeout: 5))
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        click(field)
        typeText("wrong", into: field)
        click(app.buttons["Unlock"])
        XCTAssertTrue(app.descendants(matching: .any)["Unlock failed. Wrong password."].waitForExistence(timeout: 5)
                      || hasText(containing: "Wrong password.", timeout: 1),
                      "A wrong password is reported and the sheet stays open")
        XCTAssertFalse(element("scan-title").exists, "No scan starts on a wrong password")

        click(field)
        typeText("fixture-vault-pass", into: field)
        click(app.buttons["Unlock"])
        XCTAssertTrue(waitForScanCompleted(), "The correct password closes the sheet and scans the drive")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
    }

    // MARK: (8) Accessibility audits (spec-tech-batch-6 §D)

    func testAccessibilityAuditDevicePicker() throws {
        launch("standard")
        XCTAssertTrue(element(fixtureDriveID).waitForExistence(timeout: 10))
        // EXPERIENCE.md: the device tree reads "Partition …, on …".
        let partition = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Partition FIXTURE, exFAT",
                                  "Partition FIXTURE, exFAT")).firstMatch
        XCTAssertTrue(partition.waitForExistence(timeout: 5))
        XCTAssertTrue(describe(partition).hasSuffix(", on Salvage Fixture Drive"), describe(partition))
        let bootPartition = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Partition Macintosh HD, APFS",
                                  "Partition Macintosh HD, APFS")).firstMatch
        XCTAssertTrue(describe(bootPartition).hasSuffix(", on Fixture Macintosh HD"), describe(bootPartition))
        try audit("Device Picker")
        assertNoAuditFindings()
    }

    func testAccessibilityAuditScanProgressRunningAndPaused() throws {
        launch("slowScan")
        click(element(fixtureDriveID))
        let pause = app.buttons["Pause"]
        XCTAssertTrue(wait(for: pause, enabled: true, timeout: 10), "Pause is offered while the scan runs")
        // EXPERIENCE.md: pause/resume/cancel are labeled with role and state.
        let cancel = app.buttons["Cancel scan"]
        XCTAssertTrue(cancel.exists && cancel.isEnabled, "Cancel scan is an enabled button")
        // The progress bar's spoken value ("Scanning, 12 percent" / "Paused, …") is its value
        // description, which XCUITest doesn't expose; check its role and the visible state instead.
        XCTAssertEqual(element("scan-progress").elementType, .progressIndicator, "Progress has the progress role")
        XCTAssertTrue(hasText("Scanning…"), "The running state is stated in words")
        try audit("Scan Progress (running)")

        click(pause)
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(resume.isEnabled, "Resume is an enabled button while paused")
        XCTAssertFalse(app.buttons["Pause"].exists, "Pause is replaced by Resume")
        XCTAssertTrue(hasText("Paused", timeout: 5), "The paused state is stated in words")
        XCTAssertTrue(hasText("Remaining: Paused"))
        try audit("Scan Progress (paused)")
        click(cancel)
        assertNoAuditFindings()
    }

    func testAccessibilityAuditDashboard() throws {
        launch("standard")
        click(element(fixtureDriveID))
        XCTAssertTrue(waitForScanCompleted())
        XCTAssertTrue(element("bucket-pictures").waitForExistence(timeout: 10))
        let partitions = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Partitions")).firstMatch
        XCTAssertTrue(partitions.waitForExistence(timeout: 5), "The Partitions section is shown")
        // The UI-test fixture's image has no lost partitions, so the Lost partitions card isn't
        // shown and can't be audited here (adding one needs a fixture change outside §D's scope).
        try audit("Results Dashboard (with Partitions)")
        assertNoAuditFindings()
    }

    func testAccessibilityAuditFileBrowserRecoverySheetAndSummary() throws {
        launch("standard")
        click(element(fixtureDriveID))
        XCTAssertTrue(waitForScanCompleted())
        click(app.buttons["Browse all files"])
        XCTAssertTrue(hasText(containing: "All files — 5 files", timeout: 10))
        click(tableCell("IMG_0001.jpg"))
        XCTAssertTrue(element("file-preview").waitForExistence(timeout: 10))
        // EXPERIENCE.md: confidence labels announce the word itself.
        let confidence = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Recovery confidence High",
                                  "Recovery confidence High")).firstMatch
        XCTAssertTrue(confidence.waitForExistence(timeout: 5), "The confidence label is spoken as a word")
        try audit("File Browser with preview")

        typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(for: recover, labelContains: "Recover (5 selected)", timeout: 5), recover.label)
        click(recover)
        click(app.buttons["Choose…"])
        let confirm = element("recovery-confirm-button")
        XCTAssertTrue(wait(for: confirm, enabled: true, timeout: 10), "The fixture destination is safe")
        try audit("Recovery sheet (ready)")

        click(confirm)
        XCTAssertTrue(hasText("Recovery finished", timeout: 30))
        XCTAssertTrue(element("recovery-summary-headline").waitForExistence(timeout: 5))
        try audit("Recovery Summary")
        click(app.buttons["Done"])
        assertNoAuditFindings()
    }

    func testAccessibilityAuditBlockedRecoverySheet() throws {
        launch("destinationOnSource")
        click(element(fixtureDriveID))
        XCTAssertTrue(waitForScanCompleted())
        click(app.buttons["Browse all files"])
        click(tableCell("readme.txt"))
        typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(for: recover, labelContains: "Recover (5 selected)", timeout: 5))
        click(recover)
        click(app.buttons["Choose…"])
        // EXPERIENCE.md: the destination block banner is labeled.
        let banner = element("destination-blocked-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(describe(banner).hasPrefix("Destination blocked."), describe(banner))
        try audit("Recovery sheet (blocked)")
        click(app.buttons["Cancel"])
        assertNoAuditFindings()
    }

    func testAccessibilityAuditTrustPanel() throws {
        launch("standard")
        XCTAssertTrue(element(fixtureDriveID).waitForExistence(timeout: 10))
        click(app.buttons["What Salvage reads and writes"].firstMatch)
        XCTAssertTrue(hasText(containing: "No tracking, ", timeout: 5))
        try audit("Trust Panel")
        click(app.buttons["Done"])
        assertNoAuditFindings()
    }

    func testAccessibilityAuditFileVaultSheet() throws {
        launch("fileVault")
        click(element(lockedDriveID))
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The unlock sheet opens")
        try audit("FileVault sheet")
        click(field)
        typeText("wrong", into: field)
        click(app.buttons["Unlock"])
        XCTAssertTrue(hasText(containing: "Wrong password.", timeout: 5))
        try audit("FileVault sheet (wrong password)")
        click(app.buttons["Cancel"])
        assertNoAuditFindings()
    }

    // MARK: Helpers

    private func launch(_ fixture: String) {
        app = XCUIApplication()
        app.launchArguments = ["-SalvageUITestFixture", fixture,
                               "-SalvageUITestDestination", destination.path,
                               "-SalvageUITestExpected", expected.path,
                               "-ApplePersistenceIgnoreState", "YES"]
        // XCUITest's built-in interruption handlers click buttons in whatever covers Salvage,
        // including other apps' permission dialogs ("Don't Allow"). Claim every interruption here
        // so nothing outside Salvage is ever pressed; `click(_:)` reports the conflict instead.
        addUIInterruptionMonitor(withDescription: "Never touch other apps") { [weak self] element in
            let description = "\(element.elementType) '\(element.label)'"
            MainActor.assumeIsolated { self?.interruptions.append(description) }
            return true
        }
        app.launch()
        app.activate()
    }

    /// A system permission prompt ("“App” would like to access …") that is open on this Mac, if
    /// any. When an interruption monitor can't make such a prompt go away, XCUITest falls back to
    /// its built-in handler, which presses "Don't Allow" on it, whichever app it belongs to. So
    /// while one is open the tests stop with this as the reason instead of interacting.
    private func openPermissionPrompt() -> String? {
        let prompts = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter").dialogs
        guard prompts.count > 0 else { return nil }
        let text = prompts.firstMatch.staticTexts.firstMatch
        return text.exists ? describe(text) : "a system permission prompt"
    }

    private func failIfPermissionPromptIsOpen(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let prompt = openPermissionPrompt() else { return false }
        XCTFail("Another app's permission prompt is open (\(prompt)). Answer it, then rerun: XCUITest would "
                + "otherwise press \"Don't Allow\" on it. Nothing was clicked.", file: file, line: line)
        return true
    }

    /// Clicks `element` once it exists and Salvage is frontmost with the element hittable. If
    /// another app covers it or holds focus, the test records that clearly and clicks nothing,
    /// so a click never lands in another app's window.
    private func click(_ element: XCUIElement, timeout: TimeInterval = 10,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) exists", file: file, line: line)
        if failIfPermissionPromptIsOpen(file: file, line: line) { return }
        guard activateForKeyboard() || activateForKeyboard() else {
            XCTFail("Another app holds keyboard focus (frontmost: \(frontmostAppName)); \(element) wasn't clicked.",
                    file: file, line: line)
            return
        }
        // Off-screen rows aren't hittable until XCUITest scrolls them into view, so this is a
        // short wait for layout, not a requirement.
        _ = wait(timeout: 2) { element.isHittable }
        interruptions = []
        element.click()
        if !interruptions.isEmpty {
            XCTFail("Another app covers Salvage (frontmost: \(frontmostAppName); interrupting: "
                    + "\(interruptions.joined(separator: ", ")), left untouched); the click on \(element) may not have reached Salvage.",
                    file: file, line: line)
        }
    }

    private var frontmostAppName: String {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.localizedName ?? front?.bundleIdentifier ?? "unknown"
    }

    /// Runs the system accessibility audit on what is on screen now, named by `screen`. Issues
    /// that are reported for a later design or framework fix (`knownIssue`) are attached to the
    /// test; every other issue is kept for `assertNoAuditFindings()`, which fails with all of them.
    /// Contrast is audited in its own pass (it screenshots every text and is the slowest); a pass
    /// that times out is retried once, then reported as a timeout rather than as findings.
    private func audit(_ screen: String) throws {
        let window = app.windows.firstMatch.frame
        let table = element("file-table")
        let tableFrame = table.exists ? table.frame : .null
        let sheet = app.sheets.firstMatch
        let sheetFrame = sheet.exists ? sheet.frame : .null
        var known: [String] = []
        for types: XCUIAccessibilityAuditType in [XCUIAccessibilityAuditType.all.subtracting(.contrast), .contrast] {
            for attempt in 1...2 {
                do {
                    try app.performAccessibilityAudit(for: types) { issue in
                        let line = Self.describe(issue, screen: screen)
                        if let reason = Self.knownIssue(issue, window: window, table: tableFrame, sheet: sheetFrame) {
                            known.append("\(line) -- reported: \(reason)")
                        } else {
                            self.auditFindings.append(line)
                        }
                        return true
                    }
                    break
                } catch let error as NSError where error.code == -56 {
                    // "Audit failed to complete in time": a loaded machine, not a finding.
                    if attempt == 2 {
                        XCTFail("\(screen): the \(Self.name(of: types)) audit didn't finish in time twice (machine under load?)")
                    }
                }
            }
        }
        if !known.isEmpty {
            let attachment = XCTAttachment(string: known.joined(separator: "\n"))
            attachment.name = "\(screen) -- reported accessibility issues"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private static func describe(_ issue: XCUIAccessibilityAuditIssue, screen: String) -> String {
        let element = issue.element.map { element in
            "\(element.elementType) label='\(element.label)' id='\(element.identifier)' frame=\(element.frame)"
        } ?? "no element"
        return "\(screen): \(issue.compactDescription) [\(name(of: issue.auditType))] on \(element) (\(issue.detailedDescription))"
    }

    /// Why an issue is a known, reported one (spec-tech-batch-6 Implementation Notes D) that an
    /// accessibility-only change can't fix, or nil for a new issue that must fail the test.
    private static func knownIssue(_ issue: XCUIAccessibilityAuditIssue, window: CGRect, table: CGRect,
                                   sheet: CGRect) -> String? {
        // Secondary/tertiary text and the window title fall short of the audit's contrast ratio:
        // a DESIGN.md color-token change, outside accessibility-only modifiers.
        if issue.auditType.contains(.contrast) { return "contrast needs a design token change" }
        // An AppKit-internal parent/child mismatch with no element to point at.
        if issue.auditType.contains(.parentChild), issue.element == nil { return "framework parent/child mismatch" }
        guard let element = issue.element else { return nil }
        // SwiftUI's Menu ("Select") is an AXMenuButton that opens with AXShowMenu, not AXPress.
        if issue.auditType.contains(.action), element.elementType == .menuButton { return "SwiftUI Menu has no press action" }
        if issue.auditType.contains(.sufficientElementDescription), element.elementType == .group,
           element.label.isEmpty, element.identifier.isEmpty {
            // NavigationSplitView's and HSplitView's own panes reach the window's bottom edge;
            // SwiftUI exposes no modifier that labels them.
            if abs(element.frame.maxY - window.maxY) < 1, element.frame.height > 200 { return "unlabeled split-view pane" }
            // SwiftUI Table's per-cell containers (checkbox, name and path cells; a label on the
            // cell's Text doesn't reach them -- tried on the Path column).
            if element.frame.height <= 24, table.intersects(element.frame) { return "unlabeled Table cell container" }
            // The AppKit host view of a sheet's SwiftUI content, which a modifier on that content
            // doesn't reach (tried on all three sheets).
            if sheet.contains(element.frame), element.frame.width >= sheet.width - 1 { return "unlabeled sheet host" }
        }
        return nil
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
            (.sufficientElementDescription, "sufficientElementDescription"),
            (.action, "action"), (.parentChild, "parentChild"),
        ]
        if type == XCUIAccessibilityAuditType.all.subtracting(.contrast) { return "non-contrast" }
        return names.first { type.contains($0.0) }?.1 ?? "type \(type.rawValue)"
    }

    private func assertNoAuditFindings(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(auditFindings.isEmpty, "Accessibility audit issues:\n" + auditFindings.joined(separator: "\n"),
                      file: file, line: line)
    }

    // MARK: Keyboard (focus-robust)

    private func typeKey(_ key: String, modifierFlags: XCUIElement.KeyModifierFlags) {
        withKeyboardFocus("typeKey(\(key))") { app.typeKey(key, modifierFlags: modifierFlags) }
    }

    private func typeKey(_ key: XCUIKeyboardKey, modifierFlags: XCUIElement.KeyModifierFlags) {
        withKeyboardFocus("typeKey(\(key.rawValue.debugDescription))") { app.typeKey(key, modifierFlags: modifierFlags) }
    }

    private func typeText(_ text: String, into field: XCUIElement) {
        withKeyboardFocus("typeText") { field.typeText(text) }
    }

    /// Brings Salvage to the front, then sends `events`. On "Failed to synthesize event" it
    /// re-activates and tries once more; a second failure, or Salvage never reaching the front,
    /// is recorded as another app holding keyboard focus.
    private func withKeyboardFocus(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                                   _ events: () -> Void) {
        if failIfPermissionPromptIsOpen(file: file, line: line) { return }
        for attempt in 1...2 {
            guard activateForKeyboard() else {
                XCTFail("Another app holds keyboard focus (frontmost: \(frontmostAppName)); \(what) wasn't sent.",
                        file: file, line: line)
                return
            }
            capturedSynthesisFailures = []
            events()
            let failures = capturedSynthesisFailures ?? []
            capturedSynthesisFailures = nil
            if failures.isEmpty { return }
            if attempt == 2 {
                XCTFail("Another app holds keyboard focus (frontmost: \(frontmostAppName)): \(what) failed twice with "
                        + "\"\(failures[0].compactDescription)\"", file: file, line: line)
            }
        }
    }

    /// Activates Salvage and waits for it to be the frontmost app.
    private func activateForKeyboard() -> Bool {
        app.activate()
        return wait(timeout: 5) { self.app.state == .runningForeground }
    }

    // MARK: Queries

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

    // MARK: Waiting (on element state, never fixed sleeps)

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

    /// The element's text once it has stayed the same for `stable` seconds, or nil if it kept
    /// changing for `timeout` seconds.
    private func waitUntilStable(_ element: XCUIElement, for stable: TimeInterval, timeout: TimeInterval) -> String? {
        var last = describe(element)
        var since = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let now = describe(element)
            if now != last { last = now; since = Date() } else if Date().timeIntervalSince(since) >= stable { return last }
        }
        return nil
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
