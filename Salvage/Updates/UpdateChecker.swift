import AppKit
import Foundation
import Observation

/// The single designated network file in Salvage (Architecture AD-12, FR-17/FR-18).
///
/// `scripts/check-no-network.sh` fails CI if any network-capable API appears in any other source
/// file, so this is the only place Salvage can ever talk to the network. It does exactly one
/// thing: when the user explicitly picks "Check for Updates…", it sends a single GET for the
/// latest GitHub release's metadata and compares its tag with the running version. It never runs
/// on launch or on a timer, never retries on its own, and never downloads or installs anything.
enum UpdateCheckOutcome: Equatable, Sendable {
    case upToDate(current: String)
    case available(version: String, current: String, releasePage: URL)
    case failed(String)
}

/// The two fields Salvage reads from GitHub's "latest release" response.
struct LatestRelease: Equatable, Sendable {
    let tag: String
    let releasePage: URL
}

enum UpdateCheckError: Error, Equatable {
    case badStatus(Int)
    case notHTTP
}

/// Numeric semantic-version comparison for release tags such as `v1.2.0` or `1.2`.
enum SemanticVersion {
    /// Parses `1.2.3`, `v1.2.3` or `V1.2` into numeric components. Pre-release and build suffixes
    /// (`-beta.1`, `+abc`) are ignored, since GitHub's "latest" release never points at a
    /// pre-release. Returns `nil` for anything that isn't dot-separated digits.
    static func components(_ raw: String) -> [Int]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let suffix = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<suffix]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    /// The tag as shown to people: no leading `v`.
    static func displayString(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }

    /// `true` when `candidate` is strictly newer than `current`; `nil` if either can't be parsed.
    /// Missing trailing components count as zero, so `1.2` equals `1.2.0`.
    static func isNewer(_ candidate: String, than current: String) -> Bool? {
        guard let lhs = components(candidate), let rhs = components(current) else { return nil }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

@MainActor @Observable
final class UpdateChecker {
    typealias Fetch = @Sendable () async throws -> Data

    enum State: Equatable {
        case idle
        case checking
        case finished(UpdateCheckOutcome)
    }

    nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/hsmith-dev/Salvage/releases/latest")!
    nonisolated static let releasesPage = URL(string: "https://github.com/hsmith-dev/Salvage/releases/latest")!

    nonisolated static let unreachableMessage = "Salvage couldn't reach GitHub to check for updates. Check your internet connection, then try again."
    nonisolated static let unreadableMessage = "Salvage couldn't read the release information from GitHub. Try again later."
    nonisolated static let unknownCurrentVersionMessage = "Salvage couldn't tell which version it is, so it can't compare it with the latest release."

    private(set) var state: State = .idle
    let currentVersion: String
    private let fetch: Fetch

    var isChecking: Bool { state == .checking }

    /// `fetch` is injectable so tests never touch the network. The default is the live request.
    init(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        fetch: @escaping Fetch = { try await UpdateChecker.fetchLatestRelease() }
    ) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    /// Runs one check. Only ever called from an explicit user action ("Check for Updates…").
    /// A second call while one is in flight is ignored. Failures are reported, never retried.
    func check() async {
        guard state != .checking else { return }
        state = .checking
        let outcome: UpdateCheckOutcome
        do {
            let data = try await fetch()
            outcome = Self.outcome(for: data, currentVersion: currentVersion)
        } catch let error as UpdateCheckError {
            switch error {
            case .badStatus(let code): outcome = .failed("GitHub didn't return release information (status \(code)). Try again later.")
            case .notHTTP: outcome = .failed(Self.unreadableMessage)
            }
        } catch {
            outcome = .failed(Self.unreachableMessage)
        }
        state = .finished(outcome)
    }

    /// Opens the release page in the default browser. Salvage itself downloads nothing.
    func openReleasePage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    nonisolated static func outcome(for data: Data, currentVersion: String) -> UpdateCheckOutcome {
        guard SemanticVersion.components(currentVersion) != nil else { return .failed(unknownCurrentVersionMessage) }
        guard let release = try? parseLatestRelease(data),
              let newer = SemanticVersion.isNewer(release.tag, than: currentVersion) else {
            return .failed(unreadableMessage)
        }
        let current = SemanticVersion.displayString(currentVersion)
        return newer
            ? .available(version: SemanticVersion.displayString(release.tag), current: current, releasePage: release.releasePage)
            : .upToDate(current: current)
    }

    /// Reads `tag_name` and `html_url`. The release page is only trusted if it is an https page
    /// for this repository on github.com; anything else falls back to the fixed releases page.
    nonisolated static func parseLatestRelease(_ data: Data) throws -> LatestRelease {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var page = releasesPage
        if let raw = payload.html_url, let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
           url.path.hasPrefix("/hsmith-dev/Salvage/") {
            page = url
        }
        return LatestRelease(tag: payload.tag_name, releasePage: page)
    }

    /// The live request: one GET over an ephemeral session (no cookies, no cache, no credential
    /// storage). The only headers sent are `Accept` and a bare `User-Agent: Salvage`, which
    /// GitHub's API requires; the default user agent (which names the macOS build) is replaced.
    nonisolated static func fetchLatestRelease() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: latestReleaseAPI)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Salvage", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.notHTTP }
        guard http.statusCode == 200 else { throw UpdateCheckError.badStatus(http.statusCode) }
        return data
    }
}
