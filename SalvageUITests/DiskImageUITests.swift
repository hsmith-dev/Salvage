import XCTest

/// spec-tech-batch-7 §A: scanning a disk image file. The Debug app is launched with the
/// `standard` fixture (fixture drives only, nothing real listed) plus
/// `-SalvageUITestOpenImage <path>`, which writes the fixture's exFAT volume to a file in this
/// test's temporary folder and opens it as a raw image, standing in for the open panel
/// (`DiskImageLibrary.openUITestImageIfRequested`). The scan really reads that file, read-only.
/// The recovery destination is beside the image, on the same drive, so it must be refused.
@MainActor
final class DiskImageUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var destination: URL { workDirectory.appending(path: "Destination", directoryHint: .isDirectory) }
    private var image: URL { workDirectory.appending(path: "Card Backup.img", directoryHint: .notDirectory) }

    override func setUp() async throws {
        continueAfterFailure = false
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SalvageDiskImageUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    func testOpenedImageIsListedScannedAndItsDriveRefusedAsDestination() throws {
        app = XCUIApplication()
        app.launchArguments = ["-SalvageUITestFixture", "standard",
                               "-SalvageUITestDestination", destination.path,
                               "-SalvageUITestOpenImage", image.path,
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()

        // File > Open Disk Image… is in the menu.
        XCTAssertTrue(app.menuBars.menuItems["Open Disk Image…"].waitForExistence(timeout: 10), "File > Open Disk Image… exists")

        // The image is listed under "Disk Images" with its name and size.
        let row = element("image-row-Card Backup.img")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The opened image is listed")
        XCTAssertTrue(hasText(containing: "Disk Images"), "In its own section")
        XCTAssertTrue(row.label.hasPrefix("Card Backup.img"), row.label)
        XCTAssertTrue((row.value as? String ?? "").contains("Disk image, 8.4 MB"), "\(row.value ?? "")")
        let before = try Data(contentsOf: image)

        // Selecting it scans the image file.
        row.click()
        XCTAssertTrue(waitForScanCompleted(), "The image is scanned to completion")
        XCTAssertTrue(describe(element("results-status")).contains("5 items found"), describe(element("results-status")))

        // Recovering beside the image (the same drive) is refused.
        app.buttons["Browse all files"].waitAndClick()
        let readme = element("file-table").staticTexts.matching(NSPredicate(format: "value == %@", "readme.txt")).firstMatch
        readme.waitAndClick()
        app.typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(timeout: 5) { recover.exists && self.describe(recover).contains("Recover (5 selected)") || recover.label.contains("Recover (5 selected)") })
        recover.click()
        app.buttons["Choose…"].waitAndClick()
        let banner = element("destination-blocked-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "The destination on the image's drive is blocked")
        XCTAssertFalse(element("recovery-confirm-button").isEnabled, "Recover is disabled")
        app.buttons["Cancel"].click()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [], "Nothing was written")
        XCTAssertEqual(try Data(contentsOf: image), before, "The image file is unchanged")

        // Remove from List takes it off the list.
        XCTAssertTrue(wait(timeout: 10) { !banner.exists }, "The recovery sheet closed")
        row.rightClick()
        let remove = app.menuItems["Remove from List"]
        if !remove.waitForExistence(timeout: 5) {
            add(XCTAttachment(screenshot: app.screenshot()))
            XCTFail("No context menu: \(app.menus.debugDescription)")
        }
        remove.click()
        XCTAssertTrue(wait(timeout: 5) { !row.exists }, "The image is removed from the list")
    }

    // MARK: Helpers (as in SalvageUITests)

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", identifier, identifier + "-"))
            .firstMatch
    }

    private func hasText(containing string: String, timeout: TimeInterval = 0) -> Bool {
        let byLabel = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", string)).firstMatch
        let byValue = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", string)).firstMatch
        return wait(timeout: timeout) { byLabel.exists || byValue.exists }
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
