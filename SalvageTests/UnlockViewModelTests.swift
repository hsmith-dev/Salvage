import Foundation
import SalvageCore
import Testing
@testable import Salvage

// Stories 2.4 / 2.5: the unlock sheet's model over an injected credential check. Nothing reads a
// device here; the check's Core side (keybags, unwrapping) is covered in SalvageCoreTests.

/// A decryptor stand-in for the session test.
private struct StubDecryptor: ContentDecryptor {
    func decrypt(_ ciphertext: Data, firstDataUnit: UInt64) throws -> Data { ciphertext }
}

/// Records checks; answers from a queue, or, when the queue is empty, holds the check until the
/// test releases it.
actor VerifyFake {
    private(set) var checks: [(uuid: String, kind: VolumeCredential.Kind, count: Int, credential: VolumeCredential)] = []
    private var results: [Result<Void, UnlockError>]
    private var held: CheckedContinuation<Result<Void, UnlockError>, Never>?
    private nonisolated let heldSignal = CountSignal()
    init(_ results: [Result<Void, UnlockError>]) { self.results = results }

    func verify(_ device: BlockDevice, _ credential: VolumeCredential) async -> Result<Void, UnlockError> {
        checks.append(((device.encryptedVolumeUUID ?? "").uppercased(), credential.kind, credential.count, credential))
        let result: Result<Void, UnlockError>
        if !results.isEmpty {
            result = results.removeFirst()
        } else {
            result = await withCheckedContinuation { continuation in
                held = continuation
                heldSignal.increment()
            }
        }
        return result
    }
    nonisolated func waitUntilHeld() async { await heldSignal.wait(atLeast: 1) }
    func release(_ result: Result<Void, UnlockError>) { held?.resume(returning: result); held = nil }
}

/// What `rescan` was asked to do.
@MainActor final class RescanLog {
    var calls: [(device: BlockDevice, uuids: Set<String>)] = []
}

@MainActor
private func model(_ fake: VerifyFake, _ log: RescanLog = RescanLog(), presentsSheet: Bool = true) -> UnlockViewModel {
    UnlockViewModel(presentsSheet: presentsSheet, verify: { device, credential in await fake.verify(device, credential) },
                    rescan: { device, credentials in log.calls.append((device, Set(credentials.keys))) })
}

private let plain = BlockDevice(bsdName: "disk6", displayName: "USB stick", sizeBytes: 1, isInternal: false, isBootVolume: false, mediaIdentity: 6)
private let locked = BlockDevice(bsdName: "disk7", displayName: "Vault SSD", sizeBytes: 2, isInternal: false, isBootVolume: false, mediaIdentity: 7)
    .requiringUnlock(volumeUUID: "34cfaffa-3ece-46a6-937d-93e622eaa34b", volumeName: "Secret")
private let secretUUID = "34CFAFFA-3ECE-46A6-937D-93E622EAA34B"
private let otherUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

@MainActor @Suite("FileVault unlock sheet model", .timeLimit(.minutes(1)))
struct UnlockViewModelTests {
    @Test func featureIsOnNowThatEncryptedVolumesCanBeRead() {
        #expect(FileVaultUnlockFeature.canReadUnlockedVolumes)
        #expect(UnlockViewModel().presentsSheet)
        #expect(UnlockViewModel.pickerNote(for: locked) == nil)
    }

    @Test func offersOnlyKnownEncryptedDevicesAndStartsThePlainScanAfterCancel() async {
        let fake = VerifyFake([]), log = RescanLog(), vm = model(fake, log)
        #expect(!vm.offerBeforeScan(plain))
        #expect(vm.request == nil)
        #expect(vm.offerBeforeScan(locked))
        #expect(vm.request?.title == "Secret")
        #expect(vm.request?.volumeUUID == secretUUID)
        #expect(vm.phase == .entering)
        #expect(!vm.offerBeforeScan(locked))
        // Declining hands back the device whose plain scan was waiting; nothing is re-scanned.
        #expect(vm.resolve() == locked)
        #expect(vm.request == nil)
        #expect(vm.handledVolumeUUIDs == [secretUUID])
        #expect(vm.resolve() == nil)
        #expect(await fake.checks.isEmpty)
        #expect(log.calls.isEmpty)
    }

    /// Cancel doesn't withdraw the offer for the session (selecting the locked row again offers
    /// again), but within one flow it isn't re-asked.
    @Test func cancelDoesNotRemoveTheOfferForTheSession() async {
        let vm = model(VerifyFake([]))
        #expect(vm.offerBeforeScan(locked))
        #expect(vm.resolve() == locked)
        vm.offer(fromScan: [locked])
        #expect(vm.request == nil)
        #expect(vm.offerBeforeScan(locked))
        #expect(vm.resolve() == locked)
        #expect(!vm.offerBeforeScan(plain))
        vm.offer(fromScan: [locked])
        #expect(vm.request?.volumeUUID == secretUUID)
        #expect(vm.request?.startsScanWhenResolved == false)
    }

    @Test func everyScanVolumeIsOfferedOnceInTurn() async {
        let vm = model(VerifyFake([]))
        let second = plain.requiringUnlock(volumeUUID: otherUUID, volumeName: nil)
        vm.offer(fromScan: [plain, locked, second, locked])
        #expect(vm.request?.volumeUUID == secretUUID)
        vm.offer(fromScan: [locked, second])
        #expect(vm.resolve() == nil)
        #expect(vm.request?.volumeUUID == otherUUID)
        #expect(vm.request?.title == "USB stick")
        #expect(vm.resolve() == nil)
        #expect(vm.request == nil)
        vm.offer(fromScan: [locked, second])
        #expect(vm.request == nil)
    }

    @Test func wrongPasswordUnsupportedAndToolFailureAreDistinctAndAllowRetry() async {
        let fake = VerifyFake([.failure(.wrongPassword), .failure(.wrongPassword), .failure(.unsupported), .failure(.toolFailure)])
        let log = RescanLog(), vm = model(fake, log)
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
        let first = await fake.checks
        #expect(first.count == 1 && first[0].uuid == secretUUID && first[0].kind == .password && first[0].count == 9)
        #expect(first[0].credential.isZeroed)

        vm.credentialKind = .recoveryKey
        vm.secret = "  ABCD-EFGH  "
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(vm.failureMessage == "Wrong recovery key.")
        let second = await fake.checks
        #expect(second.count == 2 && second[1].kind == .recoveryKey && second[1].count == 9) // trimmed on the bytes
        #expect(second[1].credential.isZeroed)

        // A hardware-bound volume is its own plain message, never "wrong password".
        vm.secret = "right but useless"
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(vm.phase == .failed(.unsupported))
        #expect(vm.failureMessage == UnlockViewModel.Copy.unsupported)
        #expect(vm.failureMessage != UnlockViewModel.Copy.wrongPassword)

        vm.secret = "fourth"
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(vm.failureMessage == "Couldn't unlock this volume — try again or use your recovery key.")
        #expect(vm.request != nil) // Still open: the user may retry or cancel.
        #expect(log.calls.isEmpty)
        #expect(vm.unlockedCredentials.isEmpty)
    }

    @Test func blankRecoveryKeyIsNotSubmitted() async {
        let fake = VerifyFake([]), vm = model(fake)
        #expect(vm.offerBeforeScan(locked))
        vm.credentialKind = .recoveryKey
        vm.secret = "   "
        vm.submit()
        #expect(vm.secret.isEmpty)
        #expect(vm.phase == .entering)
        await vm.waitForPendingUnlock()
        #expect(await fake.checks.isEmpty)
    }

    /// Pre-scan path: a correct password closes the sheet and starts the scan with the credential
    /// (its key recorded, its secret already zeroed) instead of the plain scan.
    @Test func correctPasswordBeforeTheScanStartsItWithTheVolumeUnlocked() async throws {
        let fake = VerifyFake([.success(())]), log = RescanLog(), vm = model(fake, log)
        #expect(vm.offerBeforeScan(locked))
        vm.secret = "spike-pass-123"
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(vm.request == nil)
        #expect(vm.failureMessage == nil)
        #expect(log.calls.count == 1)
        #expect(log.calls.first?.device == locked)
        #expect(log.calls.first?.uuids == [secretUUID])
        let credential = try #require(vm.unlockedCredentials[secretUUID])
        #expect(credential.isZeroed)
        // The scan it started reports the same volume no longer (it's unlocked); if it did, it
        // isn't asked about again in this flow.
        vm.offer(fromScan: [locked])
        #expect(vm.request == nil)
        // A new selection is a new flow: the old keys are dropped.
        #expect(!vm.offerBeforeScan(plain))
        #expect(vm.unlockedCredentials.isEmpty)
    }

    /// Post-scan path with two encrypted volumes: the re-scan waits until both have been asked
    /// about, then carries every key unlocked in the flow.
    @Test func afterAScanEveryVolumeIsAskedThenOneRescanCarriesAllKeys() async {
        let fake = VerifyFake([.success(()), .success(())]), log = RescanLog(), vm = model(fake, log)
        let second = plain.requiringUnlock(volumeUUID: otherUUID, volumeName: "Other")
        vm.offer(fromScan: [locked, second])
        vm.secret = "one"
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(vm.request?.volumeUUID == otherUUID)
        #expect(log.calls.isEmpty)
        vm.secret = "two"
        vm.submit()
        await vm.waitForPendingUnlock()
        #expect(vm.request == nil)
        #expect(log.calls.count == 1)
        #expect(log.calls.first?.uuids == [secretUUID, otherUUID])

        // Declining the second still re-scans with the first.
        let other = RescanLog(), vm2 = model(VerifyFake([.success(())]), other)
        vm2.offer(fromScan: [locked, second])
        vm2.secret = "one"
        vm2.submit()
        await vm2.waitForPendingUnlock()
        #expect(other.calls.isEmpty)
        #expect(vm2.resolve() == nil)
        #expect(other.calls.count == 1 && other.calls.first?.uuids == [secretUUID])
    }

    /// Cancel during "Unlocking…" closes the sheet at once; a late success is dropped (the check
    /// only read the device) and nothing is re-scanned, and the waiting scan starts afterwards.
    @Test func cancelWhileUnlockingDropsALateResult() async {
        let fake = VerifyFake([]), log = RescanLog(), vm = model(fake, log)
        #expect(vm.offerBeforeScan(locked))
        vm.secret = "pw"
        vm.submit()
        await fake.waitUntilHeld()
        #expect(vm.phase == .unlocking)
        #expect(vm.resolve() == locked)
        #expect(vm.request == nil)
        await fake.release(.success(()))
        await vm.waitForPendingUnlock()
        #expect(log.calls.isEmpty)
        #expect(vm.unlockedCredentials.isEmpty)
        #expect(vm.request == nil && vm.phase == .entering)
        #expect(await fake.checks[0].credential.isZeroed)
    }

    /// With the sheet withheld (`presentsSheet: false`), both paths produce plain guidance instead.
    @Test func withheldSheetShowsGuidanceOnBothPaths() async {
        let fake = VerifyFake([]), vm = model(fake, presentsSheet: false)
        #expect(vm.guidance == nil)
        #expect(!vm.offerBeforeScan(locked))
        #expect(vm.request == nil)
        #expect(vm.guidance == UnlockViewModel.Copy.encryptedNotSupported)
        let second = plain.requiringUnlock(volumeUUID: otherUUID, volumeName: nil)
        vm.offer(fromScan: [locked, second, second])
        #expect(vm.request == nil)
        #expect(vm.guidanceVolumeUUIDs == [secretUUID, otherUUID])
        #expect(!vm.offerBeforeScan(plain))
        #expect(vm.guidance == nil)
        #expect(await fake.checks.isEmpty)
        #expect(UnlockViewModel.pickerNote(for: locked, sheetEnabled: false) == UnlockViewModel.Copy.encryptedNotSupported)
        #expect(UnlockViewModel.pickerNote(for: plain, sheetEnabled: false) == nil)
        let bootLocked = BlockDevice(bsdName: "disk0", displayName: "Boot", sizeBytes: 1, isInternal: true, isBootVolume: true, mediaIdentity: 1)
            .requiringUnlock(volumeUUID: secretUUID, volumeName: nil)
        #expect(UnlockViewModel.pickerNote(for: bootLocked, sheetEnabled: false) == nil)
    }

    @Test func copyMatchesExperienceAndHasNoJargon() {
        #expect(UnlockViewModel.Copy.wrongPassword == "Wrong password.")
        #expect(UnlockViewModel.Copy.toolFailure == "Couldn't unlock this volume — try again or use your recovery key.")
        #expect(UnlockViewModel.Copy.unsupported != UnlockViewModel.Copy.wrongPassword)
        for text in [UnlockViewModel.Copy.subtitle, UnlockViewModel.Copy.unsupported, UnlockViewModel.Copy.encryptedNotSupported] {
            for jargon in ["diskutil", "APFS", "EACCES", "rdisk", "stdin", "plist", "APSB", "slice", "BSD", "T2", "XTS", "keybag", "KEK"] {
                #expect(!text.localizedCaseInsensitiveContains(jargon), "jargon \(jargon) in: \(text)")
            }
        }
    }
}

/// The app's preview/recovery path decrypts through the session's decryptors.
@Suite("Source session decryptors")
struct SourceSessionDecryptorTests {
    @Test func sessionContentCarriesItsDecryptors() {
        let session = SourceSession(device: plain, reader: EmptyBlockReader(), decryptors: [secretUUID: StubDecryptor()], close: {})
        #expect(session.content.decryptors.keys.contains(secretUUID))
        #expect(SourceSession(device: plain, reader: EmptyBlockReader(), close: {}).content.decryptors.isEmpty)
    }
}

private struct EmptyBlockReader: BlockReader {
    var sizeBytes: Int64 { 0 }
    func read(at offset: Int64, count: Int) async throws -> Data { Data() }
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
