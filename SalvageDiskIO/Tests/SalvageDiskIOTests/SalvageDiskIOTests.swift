import Testing
@testable import SalvageDiskIO

@Suite("SalvageDiskIO scaffold")
struct SalvageDiskIOScaffoldTests {
    @Test("module loads and can see SalvageCore")
    func moduleLoads() {
        #expect(!SalvageDiskIO.scaffoldVersion.isEmpty)
    }
}
