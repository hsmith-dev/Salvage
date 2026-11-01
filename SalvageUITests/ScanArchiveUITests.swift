import XCTest

/// spec-tech-batch-7 §B: save a scan, open it in a fresh launch, reconnect the drive, recover.
/// Uses the DEBUG fixture (`-SalvageUITestFixture standard`): the fixture drive is an in-memory
/// exFAT image, and `-SalvageUITestArchive <path>` stands in for the save and open panels, so the
/// saved scan goes only into this test's temporary folder.
@MainActor
final class ScanArchiveUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var destination: URL { workDirectory.appending(path: "Destination", directoryHint: .isDirectory) }
    private var expected: URL { workDirectory.appending(path: "Expected", directoryHint: .isDirectory) }
    private var archive: URL { workDirectory.appending(path: "Fixture.salvagescan", directoryHint: .isDirectory) }
    private let fixtureDriveID = "device-row-disk991"
    private let reconnectMessage = "Reconnect Salvage Fixture Drive to preview or recover these files."

    override func setUp() async throws {
        continueAfterFailure = false
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SalvageArchiveUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    func testSaveOpenReconnectAndRecover() throws {
        // 1. Scan and save.
        launch()
        element(fixtureDriveID).waitAndClick()
        XCTAssertTrue(waitForScanCompleted(), "The fixture drive scans to completion")
        element("save-scan").waitAndClick()
        let info = archive.appending(path: "Info.json", directoryHint: .notDirectory)
        let files = archive.appending(path: "Files.bin", directoryHint: .notDirectory)
        XCTAssertTrue(wait(timeout: 10) { FileManager.default.fileExists(atPath: files.path) && FileManager.default.fileExists(atPath: info.path) },
                      "The saved scan is written where it was asked to go")
        app.terminate()

        // 2. A fresh launch opens it with no source: results, but no preview or recovery yet.
        launch()
        XCTAssertTrue(element(fixtureDriveID).waitForExistence(timeout: 10))
        XCTAssertTrue(hasText("Select a device to start scanning.", timeout: 5))
        app.activate()
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Open Scan…"].waitAndClick()
        XCTAssertTrue(hasText(reconnectMessage, timeout: 10), "The reopened scan asks for its drive")
        XCTAssertTrue(waitForScanCompleted(timeout: 10))
        XCTAssertTrue(describe(element("results-status")).contains("5 items found"), describe(element("results-status")))

        app.buttons["Browse all files"].waitAndClick()
        XCTAssertTrue(hasText(containing: "All files — 5 files", timeout: 10))
        tableCell("readme.txt").waitAndClick()
        app.typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(timeout: 5) { recover.exists && recover.label.contains("Recover (5 selected)") }, recover.label)
        XCTAssertFalse(recover.isEnabled, "Recover stays off until the drive is reconnected")

        // 3. Reconnect: the same fixture drive (same identity, size and layout) is adopted.
        // Other apps on a shared desktop can take the foreground; bring Salvage back before clicking.
        // A click while another app is in front can be lost, and pressing Reconnect twice is harmless,
        // so bring Salvage forward and press again once if nothing happened.
        let reconnect = element("reconnect-source")
        for _ in 0..<2 where hasText(reconnectMessage) {
            app.activate()
            _ = wait(timeout: 5) { self.app.state == .runningForeground }
            XCTAssertTrue(wait(timeout: 5) { reconnect.isHittable }, "Reconnect is inside the window: \(reconnect.frame)")
            reconnect.waitAndClick()
            if wait(timeout: 10, until: { !self.hasText(self.reconnectMessage) }) { break }
        }
        XCTAssertTrue(wait(timeout: 5) { !self.hasText(self.reconnectMessage) },
                      "The reconnect message goes away: \(describe(element("reconnect-message")))")
        XCTAssertTrue(wait(timeout: 5) { recover.isEnabled }, "Reconnecting the same drive turns recovery on")

        // 4. Recover from the reopened scan; the copies are byte-identical.
        app.activate()
        recover.click()
        XCTAssertTrue(hasText("Recover 5 files", timeout: 5))
        app.buttons["Choose…"].click()
        let confirm = element("recovery-confirm-button")
        XCTAssertTrue(wait(timeout: 10) { confirm.exists && confirm.isEnabled }, "The fixture destination is safe")
        confirm.click()
        XCTAssertTrue(hasText("Recovery finished", timeout: 30))
        app.buttons["Done"].click()

        let roots = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        let root = try XCTUnwrap(roots.first)
        for path in ["DCIM/IMG_0001.jpg", "DCIM/IMG_0002.png", "Documents/notes.txt", "Documents/budget.csv", "readme.txt"] {
            let original = try Data(contentsOf: expected.appending(path: path, directoryHint: .notDirectory))
            XCTAssertEqual(try Data(contentsOf: root.appending(path: path, directoryHint: .notDirectory)), original,
                           "\(path) is byte-identical")
        }
    }

    // MARK: Helpers

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-SalvageUITestFixture", "standard",
                               "-SalvageUITestDestination", destination.path,
                               "-SalvageUITestExpected", expected.path,
                               "-SalvageUITestArchive", archive.path,
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", identifier, identifier + "-"))
            .firstMatch
    }

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

    private func describe(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    private func waitForScanCompleted(timeout: TimeInterval = 30) -> Bool {
        let status = element("results-status")
        return wait(timeout: timeout) { status.exists && self.describe(status).hasPrefix("Scan completed") }
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
