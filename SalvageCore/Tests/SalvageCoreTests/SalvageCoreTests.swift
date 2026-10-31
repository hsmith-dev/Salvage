import Testing
@testable import SalvageCore

@Suite("SalvageCore scaffold")
struct SalvageCoreScaffoldTests {
    @Test("module loads and exposes a scaffold marker")
    func moduleLoads() {
        #expect(!SalvageCore.scaffoldVersion.isEmpty)
    }
}
