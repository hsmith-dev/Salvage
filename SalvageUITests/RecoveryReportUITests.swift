import XCTest

/// spec-tech-batch-7 §D: the recovery report, end to end through the DEBUG fixture
/// (`-SalvageUITestFixture standard`): the scan reads a synthetic in-memory exFAT image and
/// recovery writes only into a temporary folder this test creates and deletes.
@MainActor
final class RecoveryReportUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var destination: URL { workDirectory.appending(path: "Destination", directoryHint: .isDirectory) }
    private var expected: URL { workDirectory.appending(path: "Expected", directoryHint: .isDirectory) }

    override func setUp() async throws {
        continueAfterFailure = false
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SalvageReportUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    func testRecoveryWritesReportByDefaultAndOffersShowReport() throws {
        startRecoveryOfAllFiles()
        let toggle = element("recovery-report-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "The report toggle is shown")
        XCTAssertEqual(toggle.value as? Int, 1, "Save a report is on by default")
        finishRecovery()
        // Never press Show Report here: it would open another app.
        XCTAssertTrue(element("recovery-show-report-button").waitForExistence(timeout: 5), "Show Report is offered")
        app.buttons["Done"].click()

        let root = try recoveryRoot()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains("Salvage Recovery Report.csv"), "\(names)")
        XCTAssertTrue(names.contains("Salvage Recovery Report.json"), "\(names)")
        let csv = try String(contentsOf: root.appending(path: "Salvage Recovery Report.csv"), encoding: .utf8)
        XCTAssertTrue(csv.contains("Source device,Salvage Fixture Drive"), csv)
        XCTAssertTrue(csv.contains("Recovered,5\r\n"), csv)
        XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { $0.contains(",Recovered,") }.count, 5,
                       "One recovered row per file")
        let json = try Data(contentsOf: root.appending(path: "Salvage Recovery Report.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual((object["files"] as? [Any])?.count, 5)
    }

    func testTurningTheToggleOffWritesNoReport() throws {
        startRecoveryOfAllFiles()
        let toggle = element("recovery-report-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        toggle.click()
        XCTAssertTrue(wait(timeout: 5) { (toggle.value as? Int) == 0 }, "The toggle turns off")
        finishRecovery()
        XCTAssertFalse(element("recovery-show-report-button").exists, "No report, so no Show Report")
        app.buttons["Done"].click()
        let names = try FileManager.default.contentsOfDirectory(atPath: try recoveryRoot().path)
        XCTAssertFalse(names.contains { $0.hasPrefix("Salvage Recovery Report") }, "\(names)")
    }

    // MARK: Helpers

    private func startRecoveryOfAllFiles() {
        app = XCUIApplication()
        app.launchArguments = ["-SalvageUITestFixture", "standard",
                               "-SalvageUITestDestination", destination.path,
                               "-SalvageUITestExpected", expected.path,
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        let drive = element("device-row-disk991")
        XCTAssertTrue(drive.waitForExistence(timeout: 10))
        drive.click()
        let status = element("results-status")
        XCTAssertTrue(wait(timeout: 30) { status.exists && self.describe(status).hasPrefix("Scan completed") })
        let browse = app.buttons["Browse all files"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        browse.click()
        let cell = element("file-table").staticTexts.matching(NSPredicate(format: "value == %@", "readme.txt")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.click()
        app.typeKey("a", modifierFlags: .command)
        let recover = element("recover-button")
        XCTAssertTrue(wait(timeout: 5) { recover.exists && recover.label.contains("Recover (5 selected)") }, recover.label)
        recover.click()
    }

    private func finishRecovery() {
        app.buttons["Choose…"].click()
        let confirm = element("recovery-confirm-button")
        XCTAssertTrue(wait(timeout: 10) { confirm.exists && confirm.isEnabled }, "The fixture destination is safe")
        confirm.click()
        let finished = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Recovery finished", "Recovery finished")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 30))
    }

    private func recoveryRoot() throws -> URL {
        let roots = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        XCTAssertEqual(roots.count, 1, "One recovery folder")
        return try XCTUnwrap(roots.first)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", identifier, identifier + "-"))
            .firstMatch
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
