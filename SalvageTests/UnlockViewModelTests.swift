import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import Salvage

// Story 2.4: the unlock sheet's model over an injected unlocker. No diskutil runs here.

/// Records unlock and relock calls (and the order of events); answers unlocks from a queue, or,
/// when the queue is empty, holds them until the test releases them with a chosen result.
actor UnlockFake {
    private(set) var unlocks: [(uuid: String, kind: UnlockCredential.Kind, count: Int, credential: UnlockCredential)] = []
    private(set) var relocks: [String] = []
    private(set) var events: [String] = []
    private var results: [Result<UnlockOutcome, UnlockError>]
    private var held: CheckedContinuation<Result<UnlockOutcome, UnlockError>, Never>?
    private nonisolated let heldSignal = CountSignal()
    let relockSucceeds: Bool
    init(_ results: [Result<UnlockOutcome, UnlockError>], relockSucceeds: Bool = true) {
        self.results = results; self.relockSucceeds = relockSucceeds
    }
    func unlock(_ uuid: String, _ credential: UnlockCredential) async -> Result<UnlockOutcome, UnlockError> {
        unlocks.append((uuid, credential.kind, credential.count, credential))
        events.append("unlock")
        guard results.isEmpty else { return results.removeFirst() }
        return await withCheckedContinuation { continuation in
            held = continuation
            heldSignal.increment()
        }
    }
    func relock(_ bsdName: String) async -> Bool { relocks.append(bsdName); events.append("relock"); return relockSucceeds }
    /// Returns once an unlock call is being held (a signal, not a polling loop).
    nonisolated func waitUntilHeld() async { await heldSignal.wait(atLeast: 1) }
    func release(_ result: Result<UnlockOutcome, UnlockError>) {
        events.append("release")
        held?.resume(returning: result); held = nil
    }
    func note(_ event: String) { events.append(event) }
}

@MainActor
private func model(_ fake: UnlockFake, presentsSheet: Bool = true) -> UnlockViewModel {
    UnlockViewModel(presentsSheet: presentsSheet, unlock: { uuid, credential in await fake.unlock(uuid, credential) }, relock: { await fake.relock($0) })
}

private let plain = BlockDevice(bsdName: "disk6", displayName: "USB stick", sizeBytes: 1, isInternal: false, isBootVolume: false, mediaIdentity: 6)
private let locked = BlockDevice(bsdName: "disk7", displayName: "Vault SSD", sizeBytes: 2, isInternal: false, isBootVolume: false, mediaIdentity: 7)
    .requiringUnlock(volumeUUID: "34cfaffa-3ece-46a6-937d-93e622eaa34b", volumeName: "Secret")
private let secretUUID = "34CFAFFA-3ECE-46A6-937D-93E622EAA34B"
private let otherUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
private let unlocked = UnlockedVolume(volumeUUID: secretUUID, bsdName: "disk19s2", name: "Secret")

@MainActor @Suite("FileVault unlock sheet model", .timeLimit(.minutes(1)))
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
        // Declining hands back the device whose scan was waiting.
        #expect(vm.resolve() == locked)
        #expect(vm.request == nil)
        #expect(vm.handledVolumeUUIDs == [secretUUID])
        #expect(vm.resolve() == nil)
        #expect(await fake.unlocks.isEmpty)
    }

    /// Item 5: Cancel doesn't withdraw the offer for the session -- selecting the locked row again
    /// offers again -- but within one flow (selection, then that scan's results) it isn't re-asked.
    @Test func cancelDoesNotRemoveTheOfferForTheSession() async {
        let fake = UnlockFake([]), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        #expect(vm.resolve() == locked)
        // Same flow: the scan of that device reports the same encrypted volume. No re-prompt.
        vm.offer(fromScan: [locked])
        #expect(vm.request == nil)
        // A new selection is a new flow: the locked row is offered again.
        #expect(vm.offerBeforeScan(locked))
        #expect(vm.request?.volumeUUID == secretUUID)
        #expect(vm.resolve() == locked)
        // Selecting a plain device starts a fresh flow too; its scan may then offer the volume.
        #expect(!vm.offerBeforeScan(plain))
        vm.offer(fromScan: [locked])
        #expect(vm.request?.volumeUUID == secretUUID)
        #expect(vm.request?.startsScanWhenResolved == false)
    }

    /// Item 7: every encrypted volume a scan reports is offered once, one sheet after another,
    /// even when a sheet was already showing when the scan ended.
    @Test func everyScanVolumeIsOfferedOnceInTurn() async {
        let fake = UnlockFake([]), vm = model(fake)
        let second = plain.requiringUnlock(volumeUUID: otherUUID, volumeName: nil)
        vm.offer(fromScan: [plain, locked, second, locked])
        #expect(vm.request?.volumeUUID == secretUUID)
        #expect(vm.request?.startsScanWhenResolved == false)
        // Reported again while the first sheet is showing: nothing is duplicated.
        vm.offer(fromScan: [locked, second])
        #expect(vm.resolve() == nil)
        // The next one follows on its own.
        #expect(vm.request?.volumeUUID == otherUUID)
        #expect(vm.request?.title == "USB stick")
        #expect(vm.resolve() == nil)
        #expect(vm.request == nil)
        vm.offer(fromScan: [locked, second])
        #expect(vm.request == nil)

        // A sheet open when a scan ends (pre-scan path) no longer swallows that scan's volumes.
        let other = model(UnlockFake([]))
        #expect(other.offerBeforeScan(locked))
        other.offer(fromScan: [locked, second])
        #expect(other.request?.volumeUUID == secretUUID)
        #expect(other.resolve() == locked)
        #expect(other.request?.volumeUUID == otherUUID)
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
        await vm.waitForPendingUnlock()
        #expect(vm.phase == .failed(.wrongPassword))
        #expect(vm.failureMessage == "Wrong password.")
        #expect(vm.unlockedMessage == nil)
        let first = await fake.unlocks
        #expect(first.count == 1 && first[0].uuid == secretUUID && first[0].kind == .password && first[0].count == 9)
        #expect(first[0].credential.isZeroed)

        vm.credentialKind = .recoveryKey
        vm.secret = "  ABCD-EFGH  "
        vm.submit()
        #expect(vm.secret.isEmpty)
        await vm.waitForPendingUnlock()
        #expect(vm.failureMessage == "Wrong recovery key.")
        let second = await fake.unlocks
        #expect(second.count == 2 && second[1].kind == .recoveryKey && second[1].count == 9) // trimmed on the bytes
        #expect(second[1].credential.isZeroed)

        vm.secret = "third"
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(vm.phase == .failed(.toolFailure))
        #expect(vm.failureMessage == "Couldn't unlock this volume — try again or use your recovery key.")
        #expect(vm.request != nil) // Still open: the user may retry or cancel.
        #expect(await fake.relocks.isEmpty)
    }

    /// Item 9: a whitespace-only recovery key never reaches the unlocker, and the field is cleared.
    @Test func blankRecoveryKeyIsNotSubmitted() async {
        let fake = UnlockFake([]), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        vm.credentialKind = .recoveryKey
        vm.secret = "   "
        vm.submit()
        #expect(vm.secret.isEmpty)
        #expect(vm.phase == .entering)
        await vm.waitForPendingUnlock()
        #expect(await fake.unlocks.isEmpty)
    }

    @Test func successRelocksAndEndsInGuidance() async {
        let fake = UnlockFake([.success(.unlocked(unlocked))]), vm = model(fake)
        vm.offer(fromScan: [locked])
        vm.secret = "spike-pass-123"
        vm.submit()
        await vm.waitForPendingUnlock()
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

    /// Item 1: an already-unlocked volume is never relocked (Salvage didn't unlock it) and the
    /// sheet never says the credential worked.
    @Test func alreadyUnlockedIsNeverRelockedNorReportedAsCredentialSuccess() async {
        let fake = UnlockFake([.success(.alreadyUnlocked(unlocked))]), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        vm.secret = "any guess at all"
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(vm.phase == .alreadyUnlocked(unlocked))
        #expect(vm.phase != .unlocked(unlocked))
        #expect(await fake.relocks.isEmpty)
        #expect(!vm.relocked)
        #expect(vm.unlockedMessage == UnlockViewModel.Copy.alreadyUnlocked)
        #expect(!(vm.unlockedMessage ?? "").contains(UnlockViewModel.Copy.unlockedButUnreadable))
        #expect(!vm.canSubmit)
        #expect(vm.failureMessage == nil)
        #expect(vm.resolve() == locked)
    }

    @Test func failedRelockIsSaidPlainly() async {
        let fake = UnlockFake([.success(.unlocked(unlocked))], relockSucceeds: false), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        vm.secret = "pw"
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(!vm.relocked)
        #expect(vm.unlockedMessage?.hasSuffix(UnlockViewModel.Copy.notRelocked) == true)
        // Continue after the guidance still starts the waiting scan.
        #expect(vm.resolve() == locked)
    }

    /// Item 2: Cancel during "Unlocking…" closes the sheet at once, but the attempt isn't dropped:
    /// a late `.success` is relocked (Salvage unlocked it) and recorded, and the waiting scan
    /// can only start after all of that (`waitForPendingUnlock`). Deterministic: the fake signals
    /// when it holds the unlock and returns only when released; the order of events is causal.
    @Test func cancelWhileUnlockingRelocksALateSuccessBeforeTheScanStarts() async {
        let fake = UnlockFake([]), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        vm.secret = "pw"
        vm.submit()
        await fake.waitUntilHeld()
        #expect(vm.phase == .unlocking)
        #expect(vm.resolve() == locked)
        #expect(vm.request == nil)
        #expect(vm.phase == .entering)

        // What ContentView does with the returned device: wait, then start the scan.
        let scanStarted = Task { @MainActor in
            await vm.waitForPendingUnlock()
            await fake.note("scan started")
        }
        await fake.release(.success(.unlocked(unlocked)))
        await scanStarted.value
        #expect(await fake.events == ["unlock", "release", "relock", "scan started"])
        #expect(await fake.relocks == ["disk19s2"])
        #expect(vm.abandonedOutcomes == [.relocked(unlocked)])
        // The closed sheet is not reopened or changed by the late result.
        #expect(vm.request == nil)
        #expect(vm.phase == .entering)
        #expect(await fake.unlocks[0].credential.isZeroed)
    }

    /// Item 1 + 2: a late `.alreadyUnlocked` after Cancel is recorded but never relocked.
    @Test func cancelWhileUnlockingNeverRelocksAVolumeSalvageDidNotUnlock() async {
        let fake = UnlockFake([]), vm = model(fake)
        vm.offer(fromScan: [locked])
        vm.secret = "pw"
        vm.submit()
        await fake.waitUntilHeld()
        #expect(vm.resolve() == nil)
        // A new request opened meanwhile must not be touched by the late result.
        vm.offer(fromScan: [plain.requiringUnlock(volumeUUID: otherUUID, volumeName: "Other")])
        #expect(vm.request?.volumeUUID == otherUUID)
        await fake.release(.success(.alreadyUnlocked(unlocked)))
        await vm.waitForPendingUnlock()
        #expect(await fake.relocks.isEmpty)
        #expect(vm.abandonedOutcomes == [.alreadyUnlocked(unlocked)])
        #expect(vm.request?.volumeUUID == otherUUID)
        #expect(vm.phase == .entering)
    }

    /// Item 3: with the feature flag off (this build), the sheet is withheld on both paths and the
    /// same events produce plain guidance instead, once per volume.
    @Test func sheetIsWithheldBehindTheFeatureFlag() async {
        #expect(FileVaultUnlockFeature.canReadUnlockedVolumes == false)
        let fake = UnlockFake([])
        let vm = UnlockViewModel(unlock: { uuid, credential in await fake.unlock(uuid, credential) }, relock: { await fake.relock($0) })
        #expect(!vm.presentsSheet)
        #expect(vm.guidance == nil)
        // Pre-scan: a locked row doesn't open the sheet; the scan starts and guidance shows.
        #expect(!vm.offerBeforeScan(locked))
        #expect(vm.request == nil)
        #expect(vm.guidance == UnlockViewModel.Copy.encryptedNotSupported)
        #expect(vm.guidance == "This drive has a FileVault-encrypted volume. Salvage can't recover files from encrypted volumes yet; its unencrypted volumes are scanned as usual.")
        // Post-scan: no sheet either; each reported volume is explained once.
        let second = plain.requiringUnlock(volumeUUID: otherUUID, volumeName: nil)
        vm.offer(fromScan: [locked, second, second])
        #expect(vm.request == nil)
        #expect(vm.guidanceVolumeUUIDs == [secretUUID, otherUUID])
        // A plain selection starts a new flow with no guidance.
        #expect(!vm.offerBeforeScan(plain))
        #expect(vm.guidance == nil)
        vm.offer(fromScan: [second])
        #expect(vm.request == nil)
        #expect(vm.guidanceVolumeUUIDs == [otherUUID])
        #expect(await fake.unlocks.isEmpty)

        // The picker row's inline note follows the same flag.
        #expect(UnlockViewModel.pickerNote(for: locked) == UnlockViewModel.Copy.encryptedNotSupported)
        #expect(UnlockViewModel.pickerNote(for: plain) == nil)
        #expect(UnlockViewModel.pickerNote(for: locked, sheetEnabled: true) == nil)
        let bootLocked = BlockDevice(bsdName: "disk0", displayName: "Boot", sizeBytes: 1, isInternal: true, isBootVolume: true, mediaIdentity: 1)
            .requiringUnlock(volumeUUID: secretUUID, volumeName: nil)
        #expect(UnlockViewModel.pickerNote(for: bootLocked) == nil)
    }

    @Test func copyMatchesExperienceAndHasNoJargon() {
        #expect(UnlockViewModel.Copy.wrongPassword == "Wrong password.")
        #expect(UnlockViewModel.Copy.toolFailure == "Couldn't unlock this volume — try again or use your recovery key.")
        for text in [UnlockViewModel.Copy.subtitle, UnlockViewModel.Copy.unlockedButUnreadable, UnlockViewModel.Copy.relocked,
                     UnlockViewModel.Copy.notRelocked, UnlockViewModel.Copy.alreadyUnlocked, UnlockViewModel.Copy.encryptedNotSupported] {
            for jargon in ["diskutil", "APFS", "EACCES", "rdisk", "stdin", "plist", "APSB", "slice", "BSD"] {
                #expect(!text.localizedCaseInsensitiveContains(jargon), "jargon \(jargon) in: \(text)")
            }
        }
    }
}

/// A counter a test can await reaching a value: a signal, not a polling loop. Cancellation-aware,
/// so a suite's `.timeLimit` turns a regression into a failure instead of a hang.
private final class CountSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var nextID = 0
    private var waiters: [Int: (threshold: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    var value: Int { lock.withLock { count } }

    func increment() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            count += 1
            let due = waiters.filter { $0.value.threshold <= count }
            due.keys.forEach { waiters[$0] = nil }
            return due.values.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    /// Returns once the count is at least `threshold`, or the waiting task is cancelled.
    func wait(atLeast threshold: Int) async {
        let id = lock.withLock { nextID += 1; return nextID }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if count >= threshold || Task.isCancelled { return true }
                    waiters[id] = (threshold, continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }
}
