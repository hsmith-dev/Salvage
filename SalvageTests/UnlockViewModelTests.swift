import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import Salvage

// Story 2.4: the unlock sheet's model over an injected unlocker. No diskutil runs here.

/// Records unlock and relock calls; answers unlocks from a queue, or holds them until released.
actor UnlockFake {
    private(set) var unlocks: [(uuid: String, kind: UnlockCredential.Kind, count: Int, credential: UnlockCredential)] = []
    private(set) var relocks: [String] = []
    private var results: [Result<UnlockedVolume, UnlockError>]
    private var waiter: CheckedContinuation<Void, Never>?
    let relockSucceeds: Bool
    init(_ results: [Result<UnlockedVolume, UnlockError>], relockSucceeds: Bool = true) {
        self.results = results; self.relockSucceeds = relockSucceeds
    }
    func unlock(_ uuid: String, _ credential: UnlockCredential) async -> Result<UnlockedVolume, UnlockError> {
        unlocks.append((uuid, credential.kind, credential.count, credential))
        if results.isEmpty { await withCheckedContinuation { waiter = $0 }; return .failure(.toolFailure) }
        return results.removeFirst()
    }
    func relock(_ bsdName: String) async -> Bool { relocks.append(bsdName); return relockSucceeds }
    func release() { waiter?.resume(); waiter = nil }
    var isWaiting: Bool { waiter != nil }
}

@MainActor
private func model(_ fake: UnlockFake) -> UnlockViewModel {
    UnlockViewModel(unlock: { uuid, credential in await fake.unlock(uuid, credential) }, relock: { await fake.relock($0) })
}

private let plain = BlockDevice(bsdName: "disk6", displayName: "USB stick", sizeBytes: 1, isInternal: false, isBootVolume: false, mediaIdentity: 6)
private let locked = BlockDevice(bsdName: "disk7", displayName: "Vault SSD", sizeBytes: 2, isInternal: false, isBootVolume: false, mediaIdentity: 7)
    .requiringUnlock(volumeUUID: "34cfaffa-3ece-46a6-937d-93e622eaa34b", volumeName: "Secret")
private let secretUUID = "34CFAFFA-3ECE-46A6-937D-93E622EAA34B"
private let unlocked = UnlockedVolume(volumeUUID: secretUUID, bsdName: "disk19s2", name: "Secret")

/// Waits for the model's unlock Task to finish (a few ms in-process; bounded for safety).
@MainActor
private func settle(_ vm: UnlockViewModel) async {
    for _ in 0..<2_000 where vm.phase == UnlockViewModel.Phase.unlocking {
        await Task.yield(); try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor @Suite("FileVault unlock sheet model")
struct UnlockViewModelTests {
    @Test func offersOnlyKnownEncryptedDevicesAndStartsTheScanAfterCancel() async {
        let fake = UnlockFake([]), vm = model(fake)
        #expect(!vm.offerBeforeScan(plain))
        #expect(vm.request == nil)
        #expect(vm.offerBeforeScan(locked))
        #expect(vm.request?.title == "Secret")
        #expect(vm.request?.volumeUUID == secretUUID)
        #expect(vm.phase == .entering)
        // A second device can't take the sheet while one request is showing.
        #expect(!vm.offerBeforeScan(locked))
        // Declining hands back the device whose scan was waiting, and never offers it again.
        #expect(vm.resolve() == locked)
        #expect(vm.request == nil)
        #expect(vm.handledVolumeUUIDs == [secretUUID])
        #expect(!vm.offerBeforeScan(locked))
        #expect(vm.resolve() == nil)
        #expect(await fake.unlocks.isEmpty)
    }

    @Test func offersScanRequestsOnceEachWithoutStartingAnything() async {
        let fake = UnlockFake([]), vm = model(fake)
        let second = plain.requiringUnlock(volumeUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", volumeName: nil)
        vm.offer(fromScan: [plain, locked, second])
        #expect(vm.request?.volumeUUID == secretUUID)
        #expect(vm.request?.startsScanWhenResolved == false)
        #expect(vm.resolve() == nil)
        vm.offer(fromScan: [locked, second])
        #expect(vm.request?.volumeUUID == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(vm.request?.title == "USB stick")
        #expect(vm.resolve() == nil)
        vm.offer(fromScan: [locked, second])
        #expect(vm.request == nil)
    }

    @Test func wrongPasswordIsDistinctAndAllowsRetry() async {
        let fake = UnlockFake([.failure(.wrongPassword), .failure(.wrongPassword), .failure(.toolFailure)]), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        #expect(!vm.canSubmit)
        vm.secret = "guess one"
        #expect(vm.canSubmit)
        vm.submit()
        #expect(vm.secret.isEmpty) // Cleared the moment the attempt starts.
        #expect(vm.phase == .unlocking)
        #expect(!vm.canSubmit)
        await settle(vm)
        #expect(vm.phase == .failed(.wrongPassword))
        #expect(vm.failureMessage == "Wrong password.")
        #expect(vm.unlockedMessage == nil)
        let first = await fake.unlocks
        #expect(first.count == 1 && first[0].uuid == secretUUID && first[0].kind == .password && first[0].count == 9)
        #expect(first[0].credential.isZeroed)

        vm.credentialKind = .recoveryKey
        vm.secret = "  ABCD-EFGH  "
        vm.submit()
        await settle(vm)
        #expect(vm.failureMessage == "Wrong recovery key.")
        let second = await fake.unlocks
        #expect(second.count == 2 && second[1].kind == .recoveryKey && second[1].count == 9) // trimmed

        vm.secret = "third"
        vm.submit()
        await settle(vm)
        #expect(vm.phase == .failed(.toolFailure))
        #expect(vm.failureMessage == "Couldn't unlock this volume — try again or use your recovery key.")
        #expect(vm.request != nil) // Still open: the user may retry or cancel.
        #expect(await fake.relocks.isEmpty)
        #expect(vm.handledVolumeUUIDs.isEmpty)
    }

    @Test func successRelocksAndEndsInGuidance() async {
        let fake = UnlockFake([.success(unlocked)]), vm = model(fake)
        vm.offer(fromScan: [locked])
        vm.secret = "spike-pass-123"
        vm.submit()
        await settle(vm)
        #expect(vm.phase == .unlocked(unlocked))
        #expect(vm.relocked)
        #expect(await fake.relocks == ["disk19s2"])
        let message = vm.unlockedMessage ?? ""
        #expect(message.hasPrefix(UnlockViewModel.Copy.unlockedButUnreadable))
        #expect(message.hasSuffix(UnlockViewModel.Copy.relocked))
        #expect(vm.failureMessage == nil)
        #expect(!vm.canSubmit)
        #expect(vm.handledVolumeUUIDs == [secretUUID])
        #expect(vm.resolve() == nil)
        vm.offer(fromScan: [locked])
        #expect(vm.request == nil)
    }

    @Test func failedRelockIsSaidPlainly() async {
        let fake = UnlockFake([.success(unlocked)], relockSucceeds: false), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        vm.secret = "pw"
        vm.submit()
        await settle(vm)
        #expect(!vm.relocked)
        #expect(vm.unlockedMessage?.hasSuffix(UnlockViewModel.Copy.notRelocked) == true)
        // Continue after the guidance still starts the waiting scan.
        #expect(vm.resolve() == locked)
    }

    @Test func cancelWhileUnlockingDiscardsTheLateResult() async {
        let fake = UnlockFake([]), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        vm.secret = "pw"
        vm.submit()
        for _ in 0..<2_000 where !(await fake.isWaiting) { await Task.yield(); try? await Task.sleep(for: .milliseconds(1)) }
        #expect(await fake.isWaiting)
        #expect(vm.resolve() == locked)
        #expect(vm.request == nil)
        await fake.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(vm.phase == .entering)
        #expect(vm.request == nil)
    }

    @Test func copyMatchesExperienceAndHasNoJargon() {
        #expect(UnlockViewModel.Copy.wrongPassword == "Wrong password.")
        #expect(UnlockViewModel.Copy.toolFailure == "Couldn't unlock this volume — try again or use your recovery key.")
        for text in [UnlockViewModel.Copy.subtitle, UnlockViewModel.Copy.unlockedButUnreadable, UnlockViewModel.Copy.relocked, UnlockViewModel.Copy.notRelocked] {
            for jargon in ["diskutil", "APFS", "EACCES", "rdisk", "stdin", "plist", "APSB", "slice", "BSD"] {
                #expect(!text.localizedCaseInsensitiveContains(jargon), "jargon \(jargon) in: \(text)")
            }
        }
    }
}
