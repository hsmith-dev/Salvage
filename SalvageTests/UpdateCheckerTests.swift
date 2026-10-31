import Foundation
import Testing
@testable import Salvage

/// Every test injects its own fetch closure; nothing here touches the network.
@Suite("Semantic version comparison")
struct SemanticVersionTests {
    @Test(arguments: [
        ("1.0.0", "0.1.0", true),
        ("v1.0.0", "0.1.0", true),
        ("V0.2", "0.1.9", true),
        ("0.1.10", "0.1.9", true),
        ("v0.1.0", "0.1.0", false),
        ("0.1", "0.1.0", false),
        ("0.1.0", "v0.1", false),
        ("0.0.9", "0.1.0", false),
        ("v2.0.0-beta.1", "1.9.9", true),
        ("1.0.0+build7", "1.0.0", false),
    ])
    func comparesTags(candidate: String, current: String, newer: Bool) {
        #expect(SemanticVersion.isNewer(candidate, than: current) == newer)
    }

    @Test(arguments: ["", "v", "latest", "1..2", "1.2.", "v1.x", "-1.0", "１.０"])
    func rejectsUnparseableTags(tag: String) {
        #expect(SemanticVersion.components(tag) == nil)
        #expect(SemanticVersion.isNewer(tag, than: "0.1.0") == nil)
    }

    @Test func displayStringDropsLeadingV() {
        #expect(SemanticVersion.displayString("v1.2.3") == "1.2.3")
        #expect(SemanticVersion.displayString("1.2.3") == "1.2.3")
    }
}

@MainActor @Suite("Update checker")
struct UpdateCheckerTests {
    nonisolated private static func release(tag: String, page: String = "https://github.com/hsmith-dev/Salvage/releases/tag/v9.9.9") -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(page)","name":"Salvage","assets":[]}"#.utf8)
    }

    private func checker(current: String = "0.1.0", _ fetch: @escaping UpdateChecker.Fetch) -> UpdateChecker {
        UpdateChecker(currentVersion: current, fetch: fetch)
    }

    @Test func startsIdleAndNeverFetchesOnItsOwn() async {
        let probe = FetchProbe()
        let model = checker { await probe.hit(); return Self.release(tag: "v9.9.9") }
        await Task.yield()
        #expect(model.state == .idle)
        #expect(await probe.count == 0)
    }

    @Test func reportsNewerVersionWithReleasePage() async {
        let model = checker { Self.release(tag: "v9.9.9") }
        await model.check()
        #expect(model.state == .finished(.available(
            version: "9.9.9", current: "0.1.0",
            releasePage: URL(string: "https://github.com/hsmith-dev/Salvage/releases/tag/v9.9.9")!)))
    }

    @Test func reportsUpToDateForSameOrOlderTag() async {
        for tag in ["v0.1.0", "0.1.0", "0.1", "v0.0.5"] {
            let model = checker { Self.release(tag: tag) }
            await model.check()
            #expect(model.state == .finished(.upToDate(current: "0.1.0")), "tag \(tag)")
        }
    }

    @Test func untrustedReleasePageFallsBackToFixedReleasesPage() async {
        for page in ["http://github.com/hsmith-dev/Salvage/releases/tag/v9", "https://evil.example/hsmith-dev/Salvage/x",
                     "https://github.com/someone-else/Salvage/releases/tag/v9", "not a url"] {
            let model = checker { Self.release(tag: "v9.0.0", page: page) }
            await model.check()
            #expect(model.state == .finished(.available(version: "9.0.0", current: "0.1.0", releasePage: UpdateChecker.releasesPage)),
                    "page \(page)")
        }
    }

    @Test func missingReleasePageFallsBack() throws {
        let release = try UpdateChecker.parseLatestRelease(Data(#"{"tag_name":"v1.0.0"}"#.utf8))
        #expect(release == LatestRelease(tag: "v1.0.0", releasePage: UpdateChecker.releasesPage))
    }

    @Test(arguments: [
        "", "not json", "[]", "{}", #"{"tag_name": 3}"#, #"{"name":"v1.0.0"}"#, #"{"tag_name":"latest"}"#,
    ])
    func badJSONIsAPlainFailure(body: String) async {
        let model = checker { Data(body.utf8) }
        await model.check()
        #expect(model.state == .finished(.failed(UpdateChecker.unreadableMessage)))
    }

    @Test func offlineIsAPlainFailureAndIsNotRetried() async {
        let probe = FetchProbe()
        let model = checker { await probe.hit(); throw CocoaError(.fileReadUnknown) }
        await model.check()
        #expect(model.state == .finished(.failed(UpdateChecker.unreachableMessage)))
        await Task.yield()
        #expect(await probe.count == 1)
    }

    @Test func httpErrorStatusIsReported() async {
        let model = checker { throw UpdateCheckError.badStatus(404) }
        await model.check()
        guard case .finished(.failed(let message)) = model.state else {
            Issue.record("expected a failure, got \(model.state)"); return
        }
        #expect(message.contains("404"))
    }

    @Test func unknownCurrentVersionIsAPlainFailure() async {
        let model = checker(current: "") { Self.release(tag: "v1.0.0") }
        await model.check()
        #expect(model.state == .finished(.failed(UpdateChecker.unknownCurrentVersionMessage)))
    }

    @Test func overlappingChecksFetchOnce() async {
        let gate = FetchGate()
        let model = checker { await gate.wait(); return Self.release(tag: "v0.1.0") }
        let first = Task { await model.check() }
        while !model.isChecking { await Task.yield() }
        await model.check()
        #expect(model.isChecking)
        await gate.open()
        await first.value
        #expect(model.state == .finished(.upToDate(current: "0.1.0")))
        #expect(await gate.calls == 1)
    }

    @Test func liveEndpointIsTheGitHubLatestReleaseAPI() {
        #expect(UpdateChecker.latestReleaseAPI.absoluteString == "https://api.github.com/repos/hsmith-dev/Salvage/releases/latest")
        #expect(UpdateChecker.latestReleaseAPI.query == nil)
    }
}

@MainActor @Suite("Scan activity")
struct ScanActivityTests {
    @Test func tracksActiveScansAcrossWindows() {
        let activity = ScanActivity()
        let a = UUID(), b = UUID()
        #expect(!activity.isAnyScanActive)
        activity.set(a, active: true)
        activity.set(b, active: true)
        activity.set(a, active: false)
        #expect(activity.isAnyScanActive)
        activity.set(b, active: false)
        #expect(!activity.isAnyScanActive)
    }
}

private actor FetchProbe {
    private(set) var count = 0
    func hit() { count += 1 }
}

private actor FetchGate {
    private(set) var calls = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        calls += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
