import XCTest

/// File details and "why this confidence" (spec-tech-batch-7 §C), on the Debug `standard`
/// fixture (`Salvage/Testing/UITestFixtures.swift`): a synthetic exFAT image held in memory, so no
/// real device is listed or read. Copy Details isn't pressed, because that would replace whatever
/// is on the user's clipboard; its text is covered by `FileDetailsTests`.
@MainActor
final class FileDetailsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SalvageFileDetailsUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        for name in ["Destination", "Expected"] {
            try FileManager.default.createDirectory(at: workDirectory.appending(path: name, directoryHint: .isDirectory),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    func testShowDetailsExplainsConfidenceAndPreviewDisclosure() {
        app = XCUIApplication()
        app.launchArguments = ["-SalvageUITestFixture", "standard",
                               "-SalvageUITestDestination", workDirectory.appending(path: "Destination").path,
                               "-SalvageUITestExpected", workDirectory.appending(path: "Expected").path,
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()

        let drive = element("device-row-disk991")
        XCTAssertTrue(drive.waitForExistence(timeout: 10))
        drive.click()
        let status = element("results-status")
        XCTAssertTrue(wait(timeout: 90) { status.exists && self.describe(status).hasPrefix("Scan completed") })
        app.buttons["Browse all files"].click()

        let showDetails = element("show-details-button")
        XCTAssertTrue(showDetails.waitForExistence(timeout: 10))
        XCTAssertFalse(showDetails.isEnabled, "Nothing is selected yet")

        let row = element("file-table").staticTexts.matching(NSPredicate(format: "value == %@", "readme.txt")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(wait(timeout: 5) { showDetails.isEnabled })

        // Cmd-I opens the sheet.
        app.typeKey("i", modifierFlags: .command)
        let sentence = "High: found through the filesystem's own records; its data is in one piece."
        let explanation = element("confidence-explanation")
        XCTAssertTrue(explanation.waitForExistence(timeout: 5), "Cmd-I shows the details")
        XCTAssertEqual(describe(explanation), sentence)
        XCTAssertTrue(hasText("/readme.txt"), "The original path is shown")
        XCTAssertTrue(hasText("Live"))
        XCTAssertTrue(hasText("exFAT"))
        XCTAssertTrue(hasText("Found through the filesystem's records"))
        XCTAssertTrue(hasText("No sign that its data was overwritten."))
        XCTAssertTrue(hasText(containing: "Run 1: device "), "Where its bytes are")
        XCTAssertTrue(element("copy-details-button").isEnabled, "Copy Details is offered")
        app.buttons["Done"].click()
        XCTAssertTrue(wait(timeout: 5) { !self.element("copy-details-button").exists }, "Done closes the sheet")

        // The preview pane's Details disclosure shows the same sentence.
        let toggle = element("preview-details-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The preview has a Details disclosure")
        toggle.click()
        XCTAssertTrue(wait(timeout: 5) { self.element("confidence-explanation").exists }, "The Details disclosure shows the explanation")
        XCTAssertEqual(describe(element("confidence-explanation")), sentence)
    }

    // MARK: Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", identifier, identifier + "-"))
            .firstMatch
    }

    private func hasText(_ string: String, timeout: TimeInterval = 2) -> Bool {
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", string, string)).firstMatch
        return wait(timeout: timeout) { match.exists }
    }

    private func hasText(containing string: String, timeout: TimeInterval = 2) -> Bool {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", string, string)).firstMatch
        return wait(timeout: timeout) { match.exists }
    }

    private func describe(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
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
