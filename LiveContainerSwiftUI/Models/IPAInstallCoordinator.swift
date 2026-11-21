import Foundation
import SwiftUI
import UIKit
import CryptoKit
import UniformTypeIdentifiers
#if canImport(SideStoreSupport)
import SideStoreSupport
#endif

private final class IPAProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func accept(_ fraction: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard fraction >= 1 || now.timeIntervalSince(last) >= 0.08 else { return false }
        last = now; return true
    }
}

struct IPAIndependentApp: Codable, Identifiable {
    var id: String { identifier }
    let identifier: String
    let resignedIdentifier: String
    let name: String
    let openURL: URL
    let installedAt: Date
    let version: String?
}

struct IPAIdentityReview: Identifiable {
    let id = UUID()
    let name: String
    let downloadedIdentifier: String
    let listedIdentifier: String
    let iconURL: URL?
}

@MainActor final class IPAInstallCoordinator: ObservableObject {
    static let shared = IPAInstallCoordinator()
    @Published private(set) var openingIdentifier: String?
    @Published private(set) var independentApps: [IPAIndependentApp] = []
    private init(cleanupStaging: Bool = true) {
        if cleanupStaging {
            Task.detached(priority: .utility) {
                let fm = FileManager.default, directory = fm.temporaryDirectory
                let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where file.lastPathComponent.hasPrefix("IPAStore-Install-") || file.lastPathComponent.hasPrefix("IPAStore-Download-") {
                    if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 86_400 { try? fm.removeItem(at: file) }
                }
            }
        }
        if let data = UserDefaults.standard.data(forKey: "IPAIndependentApps"), let records = try? JSONDecoder().decode([IPAIndependentApp].self, from: data) {
            independentApps = records.filter { IPACertificatePolicy.acceptsLaunchURL($0.openURL, identifier: $0.identifier, resignedIdentifier: $0.resignedIdentifier) }
        }
    }
    static func verifyProgressIsolation() -> [String: Int] {
        let worker = IPAInstallCoordinator(cleanupStaging: false)
        var storeEvents = 0, progressEvents = 0
        let store = worker.objectWillChange.sink { storeEvents += 1 }
        let progress = worker.fileProgress.objectWillChange.sink { progressEvents += 1 }
        for number in 0..<200 { worker.fraction = Double(number) / 200; worker.status = "Progress \(number)" }
        withExtendedLifetime((store, progress)) {}
        return ["store_updates": storeEvents, "progress_updates": progressEvents]
    }
    @Published var certificateInstallation: IPACertificateInstallation?
    @Published var certificateInstallationMessage: String?
    private var certificateInstallReply: CheckedContinuation<Bool, Never>?
    func finishCertificateInstallation(cancelled: Bool) async {
        guard let pending = certificateInstallation else { return }
        if !cancelled {
            let accepted = await UIApplication.shared.open(pending.openURL)
            guard accepted else {
                certificateInstallationMessage = "iOS hasn’t opened this app yet. Accept Install in the iOS prompt and wait for its Home Screen icon to finish downloading, then try again. If installation failed, check the certificate, profile and device registration."
                return
            }
        }
        certificateInstallation = nil; certificateInstallationMessage = nil
        let reply = certificateInstallReply; certificateInstallReply = nil
        reply?.resume(returning: !cancelled)
    }
    func forgetIndependent(_ identifier: String) {
        independentApps.removeAll { $0.identifier == identifier }; saveIndependent()
    }
    private func saveIndependent() {
        if let data = try? JSONEncoder().encode(independentApps) { UserDefaults.standard.set(data, forKey: "IPAIndependentApps") }
    }
    @Published private var installedIdentifiers = Set<String>()
    func updateInstalledIdentifiers(_ identifiers: [String]) { let next = Set(identifiers); if next != installedIdentifiers { installedIdentifiers = next } }
    func isInstalled(_ identifier: String, independent: Bool? = nil) -> Bool {
        let external = independentApps.contains { $0.identifier == identifier }
        if let independent { return independent ? external : installedIdentifiers.contains(identifier) }
        return installedIdentifiers.contains(identifier) || external
    }
    @Published private(set) var activeID: String?
    let fileProgress = IPAFileProgressState()
    private(set) var fraction = 0.0 { didSet { if let activeJob { activeJob.fraction = fraction } else { fileProgress.fraction = fraction } } }
    private(set) var status = "" { didSet { if let activeJob { activeJob.status = status } else { fileProgress.status = status } } }
    @Published private(set) var cancelling = false
    @Published var issue: IPAInstallIssue?
    @Published var modeSwitchRequested = false
    private var modeSwitchReply: CheckedContinuation<Bool, Never>?
    @Published var nativeCopy: IPANativeCopyRequest?
    private var pendingNativeCopy: (URL, String)?
    func respondToModeSwitch(_ accepted: Bool) {
        let reply = modeSwitchReply; modeSwitchReply = nil; modeSwitchRequested = false
        if accepted { UserDefaults.standard.set("container", forKey: "IPAInstallMode") }
        reply?.resume(returning: accepted)
    }
    func requestNativeCopy(identifier: String, name: String) {
        guard !busy, UserDefaults.standard.string(forKey: "IPAInstallMode") == "independent", IPASigningState().standaloneCertificateReady else { return }
        nativeCopy = IPANativeCopyRequest(identifier: identifier, name: name)
    }
    func queueNativeCopy(_ url: URL, identifier: String) { pendingNativeCopy = (url, identifier); nativeCopy = nil }
    func startPendingNativeCopy() {
        guard let (url, identifier) = pendingNativeCopy else { return }; pendingNativeCopy = nil
        guard UserDefaults.standard.string(forKey: "IPAInstallMode") == "independent", IPASigningState().standaloneCertificateReady else { return }
        #if !IPASTORE_PREVIEW
        Task { try? await importFile(url, expectedIdentifier: identifier) }
        #endif
    }
    @Published private(set) var replacementName: String?
    @Published private(set) var identityReview: IPAIdentityReview?
    private var identityReply: CheckedContinuation<Bool, Never>?
    @Published private var identifierAliases = UserDefaults.standard.dictionary(forKey: "IPAInstalledIdentifierAliases") as? [String: String] ?? [:]
    func installedIdentifier(for variant: IPAAppVariant) -> String { identifierAliases[variant.id] ?? variant.app.bundleIdentifier }
    func respondToIdentity(_ accept: Bool, id: UUID? = nil) {
        if let id, identityReview?.id != id { return }
        identityReview = nil
        let reply = identityReply; identityReply = nil; reply?.resume(returning: accept)
    }
    private func recordInstalledIdentity(_ identifier: String) {
        guard let variant = currentVariant else { return }
        identifierAliases[variant.id] = identifier
        UserDefaults.standard.set(identifierAliases, forKey: "IPAInstalledIdentifierAliases")
    }
    private var replacementReply: CheckedContinuation<Bool, Never>?
    private var operation: Task<Void, Error>?
    private var progress: Progress?
    @Published private(set) var jobs: [IPAInstallationJob] = []
    private var activeJob: IPAInstallationJob?
    private var workerID: String?
    private var waiters: [(String, CheckedContinuation<Void, Error>)] = []
    private var observation: NSKeyValueObservation?
    private var generation = UUID()
    private var currentVariant: IPAAppVariant?
    private var retry: (() -> Void)?
    var busy: Bool { activeID != nil || jobs.contains { !$0.terminal } }
    func job(_ id: String) -> IPAInstallationJob? { jobs.first { $0.id == id && !$0.terminal } }
    func job(for variant: IPAAppVariant, independent: Bool) -> IPAInstallationJob? {
        job(IPAInstallationJob.identifier(variant, independent: independent)) ?? jobs.first {
            !$0.terminal && $0.independent == independent && $0.variant.store.id == variant.store.id &&
            $0.variant.app.bundleIdentifier.caseInsensitiveCompare(variant.app.bundleIdentifier) == .orderedSame
        }
    }
    var canRetry: Bool { retry != nil }

    func prerequisites(for version: AltStoreSourceAppVersion?, independent: Bool) -> IPAInstallIssue? {
        if let issue = IPACompatibility.issue(minimum: version?.minOSVersion, maximum: version?.maxOSVersion, current: UIDevice.current.systemVersion) { return issue }
        let signing = IPASigningState()
        if independent {
            if signing.standaloneCertificateReady { return nil }
            if signing.selectedCertificateID != IPAStandaloneCertificates.legacyID || (signing.certificateImported && !signing.accountSaved) {
                return .certificateProfile
            }
            if !signing.serviceAvailable || !signing.capabilitiesReady || !signing.accountSaved || !signing.pairingImported { return .independentSetup }
        } else if !signing.containerCertificateAvailable { return .signing }
        return nil
    }
    func start(_ variant: IPAAppVariant, independent: Bool) {
        Task { await IPASigningState.restoreAfterUpdateIfNeeded(); startPrepared(variant, independent: independent) }
    }
    private func startPrepared(_ variant: IPAAppVariant, independent: Bool) {
        if job(for: variant, independent: independent) != nil { return }
        // Feedback appears before expensive certificate checks or preparation.
        let job = IPAInstallationJob(variant: variant, independent: independent)
        jobs.removeAll { $0.id == job.id }
        jobs.append(job)
        job.task = Task {
            await Task.yield()
            do {
                try Task.checkCancellation()
                if variant.store.suggestion?.marketplaceOnly == true {
                    throw IPAInstallIssue(title: "Marketplace Edition", message: "Use the publisher’s installation method for this marketplace edition. Open Web on its library page for instructions.", action: .none)
                }
                guard let version = variant.app.latestVersion else { throw IPAInstallIssue(title: "Download Unavailable", message: "This library hasn’t supplied a download. Refresh it or check its publisher’s website.", action: .none) }
                if let missing = prerequisites(for: version, independent: independent) { throw missing }
                if IPACompatibility.requiresJIT(identifier: variant.app.bundleIdentifier, declared: variant.app.requiresJIT) { throw IPACompatibility.runtimeIssue }
                #if IPASTORE_PREVIEW
                throw IPAInstallIssue(title: "Device Build Required", message: "The interface preview cannot install apps. Use the complete build on your iPhone.", action: .none)
                #else
                if independent && !IPASigningState().standaloneCertificateReady {
                    try await acquireWorker(job.id)
                    do {
                        let preparation = Progress(totalUnitCount: 100)
                        _ = try await performIPAStoreSigningTask(["task": "prepareInstall"], progress: preparation)
                        releaseWorker(job.id)
                    } catch { releaseWorker(job.id); throw signingIssue(error) }
                }
                try await downloadAndInstall(version: version, expectedIdentifier: variant.app.bundleIdentifier, independent: independent, job: job)
                IPAFeedback.success()
                #endif
                job.fraction = 1; job.status = "Installed"
                jobs.removeAll { $0 === job }
            } catch {
                if Task.isCancelled || error is CancellationError { jobs.removeAll { $0 === job } }
                else {
                    let problem = IPAInstallIssue.from(error)
                    if problem.action == .signing || problem.action == .containerMode {
                        jobs.removeAll { $0 === job }
                        retry = nil
                    } else {
                        job.failure = problem; job.status = problem.title
                        retry = { [weak self] in self?.start(variant, independent: independent) }
                    }
                    issue = problem
                }
            }
            job.transfer = nil; job.task = nil; job.downloading = false
        }
    }
    func pause(_ id: String, paused: Bool) {
        guard let job = job(id), job.downloading, !job.cancelling else { return }
        job.paused = paused; job.status = paused ? "Paused" : "Downloading…"
        job.resetEstimate()
        job.transfer?.setPaused(paused); objectWillChange.send()
    }
    func showFailure(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }), let failure = job.failure else { return }
        retry = { [weak self] in self?.start(job.variant, independent: job.independent) }; issue = failure
    }
    func remove(_ id: String) {
        guard jobs.first(where: { $0.id == id })?.terminal == true else { cancel(id); return }
        jobs.removeAll { $0.id == id }
    }
    func cancel(_ id: String) {
        guard let job = job(id) else { return }
        job.cancelling = true; job.status = "Cancelling…"; job.transfer?.cancel(); job.task?.cancel()
        if activeJob === job { cancel() }
        if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).1.resume(throwing: CancellationError()) }
        objectWillChange.send()
    }
    func cancel() {
        cancelling = true; status = "Cancelling…"
        progress?.cancel(); operation?.cancel(); activeJob?.task?.cancel()
        respondToReplacement(false); respondToIdentity(false)
        if certificateInstallation != nil { Task { await finishCertificateInstallation(cancelled: true) } }
    }
    private func acquireWorker(_ id: String) async throws {
        try Task.checkCancellation()
        if workerID == nil && activeID == nil { workerID = id; return }
        try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        do { try Task.checkCancellation() } catch { releaseWorker(id); throw error }
    }
    private func releaseWorker(_ id: String) {
        guard workerID == id else { return }
        workerID = nil
        if !waiters.isEmpty {
            let next = waiters.removeFirst(); workerID = next.0; next.1.resume()
        }
    }
    func tryAgain() { issue = nil; retry?() }
    func respondToReplacement(_ replace: Bool) {
        replacementName = nil
        let reply = replacementReply; replacementReply = nil
        reply?.resume(returning: replace)
    }
    private func begin(id: String) {
        if workerID == nil { workerID = id }
        activeID = id; fraction = 0; status = "Preparing…"; cancelling = false
        generation = UUID()
        let token = generation
        let value = Progress(totalUnitCount: 1000); progress = value
        let gate = IPAProgressGate()
        observation = value.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] value, _ in
            let fraction = max(0, min(1, value.fractionCompleted))
            guard gate.accept(fraction) else { return }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let job = self.activeJob { job.fraction = fraction } else { self.fraction = fraction }
            }
        }
    }
    private func finish() {
        generation = UUID()
        observation = nil; progress = nil
        let worker = workerID
        activeID = nil; currentVariant = nil; operation = nil; cancelling = false; replacementName = nil; activeJob = nil
        if let worker { releaseWorker(worker) }
    }
    #if !IPASTORE_PREVIEW
    func importFile(_ url: URL, expectedIdentifier: String? = nil) async throws {
        guard !busy else { throw IPAInstallIssue(title: "Installation in Progress", message: "Wait for the current app to finish, then import this file again.", action: .none) }
        let independent = UserDefaults.standard.string(forKey: "IPAInstallMode") == "independent"
        if let missing = prerequisites(for: nil, independent: independent) { issue = missing; throw missing }
        retry = nil
        currentVariant = nil
        begin(id: "file")
        // Files belongs to the user. Copy into owned staging; never delete the original.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("IPAStore-\(UUID().uuidString).ipa")
        defer { try? FileManager.default.removeItem(at: owned); finish() }
        do {
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: url, to: owned) }.value
            let task = Task { try await installFile(owned, expectedIdentifier: expectedIdentifier, downloadWeight: 0, independent: independent) }
            operation = task
            try await task.value
        } catch is CancellationError { throw CancellationError() }
        catch { if !cancelling { issue = .from(error) }; throw error }
    }
    func importURL(_ url: URL) async throws {
        guard !busy else { throw IPAInstallIssue(title: "Installation in Progress", message: "Wait for the current installation, then try again.", action: .none) }
        let independent = UserDefaults.standard.string(forKey: "IPAInstallMode") == "independent"
        if let missing = prerequisites(for: nil, independent: independent) { issue = missing; throw missing }
        retry = { [weak self] in Task { try? await self?.importURL(url) } }
        currentVariant = nil
        begin(id: "file")
        let version = AltStoreSourceAppVersion(version: "Unknown", buildVersion: nil, releaseDate: nil, localizedDescription: nil, downloadURL: url, size: nil)
        let task = Task { try await downloadAndInstall(version: version, expectedIdentifier: nil, independent: independent) }
        operation = task
        defer { finish() }
        do { try await task.value }
        catch { if !cancelling { issue = .from(error) }; throw error }
    }
    private func downloadAndInstall(version: AltStoreSourceAppVersion, expectedIdentifier: String?, independent: Bool, job: IPAInstallationJob? = nil) async throws {
        guard ["https", "http"].contains(version.downloadURL.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        if let job { job.downloading = true; job.status = "Downloading…" }
        else { status = "Downloading…" }
        let transfer = IPADownloadTransfer(priority: URLSessionTask.highPriority, expectedBytes: version.size) { [weak self, weak job] update in
            Task { @MainActor in
                guard let self else { return }
                if let job {
                    guard job.downloading, !job.paused, !job.cancelling else { return }
                    job.record(update)
                } else if update.expected > 0 { self.fraction = Double(update.received) / Double(update.expected) * 0.4 }
            }
        }
        job?.transfer = transfer
        let owned = try await transfer.download(version.downloadURL)
        defer { try? FileManager.default.removeItem(at: owned) }
        job?.downloading = false; job?.transfer = nil; job?.paused = false
        let signature = try FileHandle(forReadingFrom: owned)
        let magic = try signature.read(upToCount: 4); try signature.close()
        guard magic == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw IPAInstallIssue(title: "Publisher Didn’t Return an IPA", message: "The download link returned a web page or an unsupported file. Refresh the library, or open its Web link and download the original IPA from its publisher, then import it in Apps.", action: .compatibleBuild)
        }
        try Task.checkCancellation()
        // Signers mutate shared keychain/engine state. Network downloads can run
        // together, but validation/signing/commit are strictly serialized.
        if let job {
            job.status = "Waiting to Install…"; job.fraction = nil
            try await acquireWorker(job.id)
            activeJob = job; currentVariant = job.variant; begin(id: job.id)
        }
        defer { if job != nil { finish() } }
        progress?.completedUnitCount = 400
        if let checksum = version.sha256 {
            status = "Verifying Download…"
            try await Task.detached(priority: .userInitiated) { try Self.verifyChecksum(owned, expected: checksum) }.value
        }
        try Task.checkCancellation()
        try await installFile(owned, expectedIdentifier: expectedIdentifier, downloadWeight: 400, independent: independent)
    }
    nonisolated private static func verifyChecksum(_ url: URL, expected: String) throws {
        let normalized = expected.lowercased()
        guard normalized.count == 64, normalized.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw IPAInstallIssue(title: "Invalid Download Checksum", message: "The library’s verification information is invalid. Refresh the library or ask its publisher to correct it.", action: .compatibleBuild) }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == normalized else {
            throw IPAInstallIssue(title: "Download Didn’t Match", message: "The IPA differs from the publisher’s checksum. Nothing was installed. Refresh its library and try again; if it continues, contact its publisher.", action: .retry)
        }
    }
    private func installFile(_ file: URL, expectedIdentifier: String?, downloadWeight: Int64, independent: Bool = false) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("IPAStore-Install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let extraction = Progress(totalUnitCount: 1)
        progress?.addChild(extraction, withPendingUnitCount: 750-downloadWeight)
        status = "Unpacking…"
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String?) in
            var error: NSError?
            let code = extractWithError(file.path, staging.path, extraction, &error)
            return (code, error?.localizedDescription)
        }.value
        try Task.checkCancellation()
        switch result.0 {
        case 0: break
        case 2: throw IPAInstallIssue(title: "Unsafe Archive", message: "This file contains unsafe paths or links. Nothing was installed. Get a fresh IPA from its developer.", action: .compatibleBuild)
        case 3, 4: throw IPAInstallIssue(title: "Archive Needs More Space", message: "The expanded app is too large, or there isn’t enough free storage. Check iPhone Storage and use a smaller compatible build.", action: .storage)
        case 5: throw CancellationError()
        default: throw IPAInstallIssue(title: "Invalid IPA", message: "This file is incomplete or is not a valid IPA archive. Download it again from the publisher, then retry or import the new file.\n\nArchive check: \(result.1 ?? "Opening ZIP").", action: .retry)
        }
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        let bundles = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey]).filter { $0.pathExtension == "app" }
        guard bundles.count == 1 else { throw IPAInstallIssue(title: "Invalid App Package", message: "An IPA must contain one app in its Payload folder. Choose an original IPA from the publisher.", action: .compatibleBuild) }
        let bundle = bundles[0]
        let bundleResource = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard bundleResource.isDirectory == true, bundleResource.isSymbolicLink != true else { throw IPAInstallIssue.incompatible }
        let plistURL = bundle.appendingPathComponent("Info.plist")
        let plistSize = try plistURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard plistSize > 0, plistSize <= 2 * 1024 * 1024 else { throw IPAInstallIssue.incompatible }
        let infoData = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty, identifier.count <= 255,
              identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
              let executable = plist["CFBundleExecutable"] as? String, executable == (executable as NSString).lastPathComponent, !executable.isEmpty,
              executable != ".", executable != "..", !executable.contains("\\"), !executable.contains("\0"),
              plist["LCPatchRevision"] == nil, plist["LCBundleIdentifier"] == nil,
              !fm.fileExists(atPath: bundle.appendingPathComponent("LCAppInfo.plist").path) else {
            throw IPAInstallIssue(title: "Original Build Required", message: "The app’s package information is missing or contains prior container modifications. Use a fresh, original IPA from its publisher.", action: .compatibleBuild)
        }
        let identityMismatch = expectedIdentifier.map { $0 != identifier } ?? false
        if let platforms = plist["CFBundleSupportedPlatforms"] as? [String], !platforms.contains("iPhoneOS") { throw IPAInstallIssue.incompatible }
        if IPACompatibility.requiresJIT(identifier: identifier) { throw IPACompatibility.runtimeIssue }
        let currentOS = UIDevice.current.systemVersion
        if let missing = IPACompatibility.issue(minimum: plist["MinimumOSVersion"] as? String, maximum: nil, current: currentOS) { throw missing }
        if let families = plist["UIDeviceFamily"] as? [Int], !families.isEmpty, !families.contains(UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1) { throw IPAInstallIssue.incompatible }
        status = "Checking Compatibility…"
        try await Task.detached(priority: .userInitiated) {
            try IPABinaryInspector.validate(bundle.appendingPathComponent(executable), currentOS: currentOS, executable: true)
            if let enumerator = fm.enumerator(at: bundle, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    if url.pathExtension == "dylib" { try IPABinaryInspector.validate(url, currentOS: currentOS, executable: false) }
                    else if url.pathExtension == "framework" {
                        guard let framework = Bundle(url: url), let binary = framework.executableURL else { throw IPAInstallIssue.incompatible }
                        try IPABinaryInspector.validate(binary, currentOS: currentOS, executable: false)
                    }
                }
            }
        }.value
        try Task.checkCancellation()
        if identityMismatch, let expectedIdentifier {
            let actualName = String((plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? identifier).prefix(100))
            identityReview = IPAIdentityReview(name: actualName, downloadedIdentifier: identifier, listedIdentifier: expectedIdentifier, iconURL: currentVariant?.app.iconURL)
            status = "Review App Identity…"
            let accepted = await withCheckedContinuation { identityReply = $0 }
            guard accepted else { throw CancellationError() }
            try Task.checkCancellation()
        }
        if independent {
            try await installValidatedIndependentBundle(bundle, identifier: identifier)
            return
        }
        let model = DataManager.shared.model
        let matches = (model.apps + model.hiddenApps).filter { $0.appInfo.bundleIdentifier() == identifier }
        guard matches.count <= 1 else { throw IPAInstallIssue(title: "Choose an App to Update", message: "Several copies of this app are installed. Manage those copies in Apps before importing another update.", action: .none) }
        let previous = matches.first
        if let previous {
            if previous.uiIsHidden || previous.uiIsLocked {
                guard try await LCUtils.authenticateUser() else { throw CancellationError() }
            }
            guard !previous.isAppRunning, !previous.uiContainers.contains(where: { MultitaskManager.isUsing(container: $0.folderName) || LCSharedUtils.getContainerUsingLCScheme(withFolderName: $0.folderName) != nil }) else { throw IPAInstallIssue(title: "Close the App First", message: "Close this app before replacing it, then try again. Its data will be kept.", action: .retry) }
            replacementName = previous.appInfo.displayName()
            let replace = await withCheckedContinuation { replacementReply = $0 }
            guard replace else { throw CancellationError() }
        }
        guard let app = LCAppInfo(bundlePath: bundle.path) else { throw IPAInstallIssue.incompatible }
        if let previous { copyConfiguration(from: previous.appInfo, to: app) }
        else { app.spoofSDKVersion = true }
        // Signing always happens in staging. A failed or cancelled operation never
        // enters the installed-app model and cannot destroy a previous version.
        app.dontSign = false
        status = "Signing…"
        let signed: (Bool, String?) = await withCheckedContinuation { continuation in
            app.patchExecAndSignIfNeed(completionHandler: { success, message in continuation.resume(returning: (success, message)) }, progressHandler: { value in
                if let value { Task { @MainActor in self.progress?.addChild(value, withPendingUnitCount: 250) } }
            }, forceSign: true)
        }
        guard signed.0 else {
            let detail = String((signed.1?.loc.ipaDisplayMessage ?? "The signer did not return a reason.").replacingOccurrences(of: bundle.path, with: "App").prefix(1200))
            throw IPAInstallIssue(title: "Signing Couldn’t Finish", message: "Nothing was installed or replaced. Verify your certificate in Settings → Manage, or try another build from this app’s publisher.\n\nDetails: \(detail)", action: .signing)
        }
        guard let executable = (NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist"))?["CFBundleExecutable"] as? String),
              checkCodeSignature((bundle.appendingPathComponent(executable).path as NSString).utf8String) else {
            throw IPAInstallIssue(title: "iOS Rejected the App Signature", message: "Nothing was installed. Verify your certificate in Settings → Manage. Use the certificate and provisioning profile that signed iPAStore, then try again.", action: .signing)
        }
        try Task.checkCancellation()
        status = "Installing…"
        let parent = previous?.uiIsShared == true ? LCPath.lcGroupBundlePath : LCPath.bundlePath
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let name = previous?.appInfo.relativeBundlePath ?? "\(UUID().uuidString).app"
        let final = parent.appendingPathComponent(name, isDirectory: true)
        let prepared = previous == nil ? final : parent.appendingPathComponent(".ipastore-\(UUID().uuidString).pending", isDirectory: true)
        try fm.moveItem(at: bundle, to: prepared)
        var committed = false
        defer { if previous != nil || !committed { try? fm.removeItem(at: prepared) } }
        if previous != nil { try IPAInstallCommit.replace(prepared: prepared, current: final) }
        guard let installed = LCAppInfo(bundlePath: final.path) else {
            if previous != nil { try IPAInstallCommit.replace(prepared: prepared, current: final) }
            throw IPAInstallIssue.incompatible
        }
        installed.relativeBundlePath = name; installed.installationDate = Date(); installed.save()
        let record = LCAppModel(appInfo: installed, delegate: previous?.delegate)
        if let previous {
            if previous.uiIsHidden { model.hiddenApps.removeAll { $0 == previous }; model.hiddenApps.append(record) }
            else { model.apps.removeAll { $0 == previous }; model.apps.append(record) }
        } else { model.apps.append(record) }
        committed = true
        // Best-effort bounded original cache allows a later native copy without
        // trying to reverse container executable patches. Never includes saves.
        await Task.detached(priority: .utility) { IPANativeOriginalCache.retain(file, identifier: identifier) }.value
        recordInstalledIdentity(identifier)
        if let variant = currentVariant { IPAActivityHistory.shared.downloaded(variant) }
        else { IPAActivityHistory.shared.imported(identifier: installed.bundleIdentifier() ?? "", name: record.displayName, version: record.version) }
        if let schemes = installed.urlSchemes() { UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes").addObjects(from: schemes.compactMap { $0 as? String }) }
        progress?.completedUnitCount = 1000
        status = "Installed"
    }
    private func copyConfiguration(from old: LCAppInfo, to app: LCAppInfo) {
        app.autoSaveDisabled = true
        app.isLocked = old.isLocked; app.isHidden = old.isHidden; app.isShared = old.isShared
        app.isJITNeeded = old.isJITNeeded; app.spoofSDKVersion = old.spoofSDKVersion
        app.doSymlinkInbox = old.doSymlinkInbox; app.containerInfo = old.containerInfo
        app.tweakFolder = old.tweakFolder; app.selectedLanguage = old.selectedLanguage; app.dataUUID = old.dataUUID
        app.orientationLock = old.orientationLock; app.dontInjectTweakLoader = old.dontInjectTweakLoader
        app.hideLiveContainer = old.hideLiveContainer; app.dontLoadTweakLoader = old.dontLoadTweakLoader
        app.doUseLCBundleId = old.doUseLCBundleId; app.fixFilePickerNew = old.fixFilePickerNew
        app.fixLocalNotification = old.fixLocalNotification; app.lastLaunched = old.lastLaunched
        app.jitLaunchScriptJs = old.jitLaunchScriptJs; app.multitaskSpecified = old.multitaskSpecified
        app.classicMode = old.classicMode; app.selected32BitEmulator = old.selected32BitEmulator
        app.remark = old.remark; app.autoSaveDisabled = false; app.save()
    }
    func confirmContainerModeIfNeeded() async -> Bool {
        let signing = IPASigningState()
        guard IPAInstalledModePolicy.needsFreeMode(selectedMode: UserDefaults.standard.string(forKey: "IPAInstallMode"), importedCertificate: signing.certificateImported, certificateOrigin: UserDefaults.standard.string(forKey: "IPACertificateOrigin")) else { return true }
        guard modeSwitchReply == nil else { return false }
        return await withCheckedContinuation { reply in modeSwitchReply = reply; modeSwitchRequested = true }
    }
    func open(_ identifier: String, preferIndependent: Bool = false) async {
        guard openingIdentifier == nil else { return }
        openingIdentifier = identifier; defer { openingIdentifier = nil }
        await Task.yield()
        if let external = independentApps.first(where: { $0.identifier == identifier }),
           preferIndependent || !DataManager.shared.model.apps.contains(where: { $0.appInfo.bundleIdentifier() == identifier }) {
            if !UIAccessibility.isReduceMotionEnabled { try? await Task.sleep(for: .milliseconds(110)) }
            IPAFeedback.appWillOpen()
            let opened = await UIApplication.shared.open(external.openURL)
            if !opened { issue = IPAInstallIssue(title: "App Couldn’t Open", message: "The app may have been removed or its signature may have expired. Try Sign Now in Settings, or remove its entry from Apps and install it again.", action: .signing) }
            return
        }
        guard let app = DataManager.shared.model.apps.first(where: { $0.appInfo.bundleIdentifier() == identifier }) else { return }
        do {
            if app.uiIsLocked { guard try await LCUtils.authenticateUser() else { return } }
            if app.uiIsJITNeeded || app.uiIs32bit {
                // JIT requires the engine's interactive launch flow; do not silently
                // bypass it or claim a successful launch from the product page.
                DataManager.shared.model.selectedTab = .apps
                issue = IPAInstallIssue(title: "Additional Runtime Setup", message: "This app needs JIT or a supported emulator. Open its settings in Apps to configure and launch it.", action: .none)
                return
            }
            try await app.runApp()
        } catch { issue = .from(error) }
    }
    private func installValidatedIndependentBundle(_ bundle: URL, identifier: String) async throws {
        if IPASigningState().standaloneCertificateReady {
            try await installCertificateBundle(bundle, identifier: identifier)
            return
        }
        guard let hostHome = getenv("LC_HOME_PATH") else { throw IPAInstallIssue.signing }
        let directory = URL(fileURLWithPath: String(cString: hostHome)).appendingPathComponent("Documents/SideStore/IPAStoreIncoming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let owned = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        try FileManager.default.copyItem(at: bundle, to: owned)
        defer { try? FileManager.default.removeItem(at: owned) }
        status = "Signing & Installing…"
        let signingProgress = Progress(totalUnitCount: 100)
        progress?.addChild(signingProgress, withPendingUnitCount: 250)
        let result: [String: String]
        do { result = try await performIPAStoreSigningTask(["task": "install", "path": owned.path, "identifier": identifier], progress: signingProgress) }
        catch { if Task.isCancelled { throw CancellationError() }; throw signingIssue(error) }
        guard result["identifier"] == identifier, let resigned = result["resignedIdentifier"], let name = result["name"],
              let raw = result["openURL"], let openURL = URL(string: raw), openURL.scheme == "sidestore-" + resigned else {
            throw IPAInstallIssue(title: "Check Your Home Screen", message: "The installer didn’t return a verifiable launch address. Check whether the app was installed before trying again.", action: .none)
        }
        independentApps.removeAll { $0.identifier == identifier }
        independentApps.append(IPAIndependentApp(identifier: identifier, resignedIdentifier: resigned, name: name, openURL: openURL, installedAt: Date(), version: currentVariant?.app.latestVersion?.version))
        if let variant = currentVariant { IPAActivityHistory.shared.downloaded(variant) }
        else { IPAActivityHistory.shared.imported(identifier: identifier, name: name, version: nil) }
        saveIndependent(); recordInstalledIdentity(identifier); status = "Installed"
    }
    private func installCertificateBundle(_ bundle: URL, identifier: String) async throws {
        let fm = FileManager.default
        let certificateID = IPAStandaloneCertificates.selectedID
        guard let credential = IPAStandaloneCertificates.credential(for: certificateID),
              let profile = IPAStandaloneCertificates.profile(for: certificateID) else { throw IPAInstallIssue.certificateProfile }
        let plugins = bundle.appendingPathComponent("PlugIns")
        let children = (try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        if !children.isEmpty {
            guard UserDefaults.standard.bool(forKey: "IPARemoveExtensions") else {
                throw IPAInstallIssue(title: "App Extensions Need Profiles", message: "This package includes extensions that need their own provisioning profiles. Enable Remove App Extensions in Installation → Signing Options to install the main app with one profile. Widgets and share extensions will then be unavailable.", action: .signing)
            }
            try fm.removeItem(at: plugins)
        }
        if UserDefaults.standard.bool(forKey: "IPARemoveWatchApp") {
            let watch = bundle.appendingPathComponent("Watch")
            if fm.fileExists(atPath: watch.path) { try fm.removeItem(at: watch) }
        } else if fm.fileExists(atPath: bundle.appendingPathComponent("Watch").path) {
            throw IPAInstallIssue(title: "Watch App Needs Provisioning", message: "Enable Remove Watch App in Installation → Signing Options to install this package with a single iPhone profile.", action: .signing)
        }
        let infoURL = bundle.appendingPathComponent("Info.plist")
        guard var info = NSDictionary(contentsOf: infoURL) as? [String: Any] else { throw IPAInstallIssue.incompatible }
        let openURL = IPACertificatePolicy.launchURL(identifier: identifier)
        var schemes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        schemes.append(["CFBundleURLName": "app.ipastore.launch", "CFBundleURLSchemes": [openURL.scheme!]])
        info["CFBundleURLTypes"] = schemes
        if UserDefaults.standard.bool(forKey: "IPAEnableFiles") { info["UIFileSharingEnabled"] = true; info["LSSupportsOpeningDocumentsInPlace"] = true }
        if UserDefaults.standard.bool(forKey: "IPAUseLegacyAppearance") { info["UIDesignRequiresCompatibility"] = true }
        if UserDefaults.standard.bool(forKey: "IPAProMotion") { info["CADisableMinimumFrameDurationOnPhone"] = true }
        if UserDefaults.standard.bool(forKey: "IPAGameMode") { info["GCSupportsGameMode"] = true }
        if UserDefaults.standard.bool(forKey: "IPAIPadFullscreen") { info["UIRequiresFullScreen"] = true }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: infoURL, options: .atomic)
        status = "Signing for iPhone…"
        let signed: (Bool, Error?) = await withCheckedContinuation { reply in
            let child = LCUtils.signStandaloneBundle(bundle, profile: profile, certificate: credential.data, password: credential.password) { reply.resume(returning: ($0, $1)) }
            if let child { progress?.addChild(child, withPendingUnitCount: 150) }
        }
        guard signed.0 else { throw signed.1 ?? IPAInstallIssue.signing }
        try Task.checkCancellation()
        status = "Preparing iOS Install…"
        let package = fm.temporaryDirectory.appendingPathComponent("IPAStore-Signed-\(UUID().uuidString).ipa")
        let archiveProgress = Progress(totalUnitCount: 1)
        progress?.addChild(archiveProgress, withPendingUnitCount: 50)
        let compressPackage = UserDefaults.standard.string(forKey: "IPAArchiveCompression") == "small"
        try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            guard IPAWriteArchiveWithCompression(bundle.deletingLastPathComponent().deletingLastPathComponent().path, package.path, archiveProgress, compressPackage, &error) else { throw error ?? CocoaError(.fileWriteUnknown) as NSError }
        }.value
        defer { try? fm.removeItem(at: package) }
        try Task.checkCancellation()
        let server = IPALocalInstallServer(package: package)
        defer { server.stop() }
        let payload = try await server.start()
        try Task.checkCancellation()
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? identifier
        guard let install = IPACertificatePolicy.installURL(payload: payload, identifier: identifier, name: name, version: info["CFBundleVersion"] as? String ?? "1") else { throw IPAInstallIssue.incompatible }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Complete iOS Installation")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        guard await UIApplication.shared.open(install) else { throw IPAInstallIssue(title: "iOS Installer Couldn’t Open", message: "Try again on your iPhone. The certificate installation route requires iOS installation services.", action: .none) }
        status = "Waiting for iOS Installation…"
        let confirmed = await withCheckedContinuation { reply in
            certificateInstallReply = reply
            certificateInstallationMessage = nil
            certificateInstallation = IPACertificateInstallation(name: name, identifier: identifier, openURL: openURL)
        }
        guard confirmed else { throw CancellationError() }
        independentApps.removeAll { $0.identifier == identifier }
        independentApps.append(IPAIndependentApp(identifier: identifier, resignedIdentifier: identifier, name: name, openURL: openURL, installedAt: Date(), version: info["CFBundleShortVersionString"] as? String))
        saveIndependent(); recordInstalledIdentity(identifier)
        if let variant = currentVariant { IPAActivityHistory.shared.downloaded(variant) }
        else { IPAActivityHistory.shared.imported(identifier: identifier, name: name, version: info["CFBundleShortVersionString"] as? String) }
        status = "Installed on iPhone"
    }
    private func signingIssue(_ error: Error) -> IPAInstallIssue {
        // Only our own bridge errors contain presentation-safe messages. External
        // authentication errors can include account/device information.
        let ns = error as NSError
        if ns.domain == "IPAStore.Installation" || ns.domain == "IPAStore.Signing" {
            return IPAInstallIssue(title: "Signing Needs Attention", message: ns.localizedDescription, action: .signing)
        }
        return IPAInstallIssue(title: "Signing Connection Unavailable", message: "Open Settings → Manage, check your account and pairing file, and verify the local VPN connection. Then try again. Independent installation requires a paid developer account.", action: .signing)
    }
    #endif
}

struct IPAInstallationOverlay: ViewModifier {
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    func body(content: Content) -> some View {
        content
            .alert("Switch to Free?", isPresented: $installer.modeSwitchRequested) {
                Button("Switch & Open") { installer.respondToModeSwitch(true) }
                Button("Cancel", role: .cancel) { installer.respondToModeSwitch(false) }
            } message: { Text("You installed this app inside iPAStore. Switch back to its original mode to open it, or add and verify your own certificate in Manage. Your app and progress stay here.") }
            .sheet(item: $installer.nativeCopy, onDismiss: { installer.startPendingNativeCopy() }) { request in IPANativeCopyPage(request: request).modifier(IPATheme()) }
            .sheet(item: $installer.certificateInstallation) { pending in
                NavigationStack {
                    Form {
                        Section {
                            Label(pending.name, systemImage: "iphone.and.arrow.forward").font(.headline)
                            Text("Accept Install in the iOS prompt, then wait for the Home Screen icon to finish. Keep iPAStore open while iOS downloads the package.")
                        }
                        Section {
                            Button("Open Installed App") { Task { await installer.finishCertificateInstallation(cancelled: false) } }
                            if let message = installer.certificateInstallationMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        } footer: { Text("The app is added to On Your iPhone only after iOS successfully opens it. An install prompt alone does not confirm installation.") }
                        Section { Button("Stop Waiting", role: .cancel) { Task { await installer.finishCertificateInstallation(cancelled: true) } } }
                    }.navigationTitle("Install on iPhone").navigationBarTitleDisplayMode(.inline)
                }.interactiveDismissDisabled().modifier(IPATheme())
            }
            .sheet(item: $installer.issue) { issue in
                if issue.action == .signing || issue.action == .containerMode {
                    IPASigningHelpSheet {
                        installer.issue = nil
                        IPASettingsNavigation.open()
                    }
                    .modifier(IPATheme())
                } else {
                    NavigationStack {
                        Form {
                            Section {
                                Label(issue.title, systemImage: "exclamationmark.circle").ipaFont(.title3, weight: .bold)
                                Text(issue.message.ipaDisplayMessage)
                            }
                            if issue.action == .storage {
                                Text("Open Settings → General → iPhone Storage. Free space, then try the installation again.")
                                    .foregroundStyle(.secondary)
                            }
                            if issue.action == .retry {
                                Button(installer.canRetry ? "Try Again" : "Import Again in Apps") {
                                    if installer.canRetry { installer.tryAgain() }
                                    else { installer.issue = nil; DataManager.shared.model.selectedTab = .apps }
                                }
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: Binding(get: { installer.identityReview }, set: { _ in })) { review in
                IPAIdentityReviewPage(review: review)
                    .onDisappear { installer.respondToIdentity(false, id: review.id) }
            }
            .confirmationDialog("Replace \(installer.replacementName ?? "App")?", isPresented: Binding(get: { installer.replacementName != nil }, set: { if !$0 { installer.respondToReplacement(false) } }), titleVisibility: .visible) {
                Button("Replace App") { installer.respondToReplacement(true) }
                Button("Cancel", role: .cancel) { installer.respondToReplacement(false) }
            } message: { Text("The new version will replace the app after signing succeeds. Its existing data and settings will be kept.") }
            .overlay(alignment: .bottom) {
                if installer.activeID == "file" {
                    IPAFileProgressView(progress: installer.fileProgress)

                }
            }
    }
}

private struct IPASigningHelpSheet: View {
    let openSettings: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            instructions
            ScrollView { instructions }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IPAStyle.canvas)
        .presentationDetents([.height(390), .large])
        .presentationDragIndicator(.visible)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Go to Settings and select a way to sign apps.")
                .ipaFont(.title3, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
            Button("Go to Settings", action: openSettings)
                .buttonStyle(IPAPillStyle(prominent: true, compact: true))

            method("Using a Certificate", symbol: "checkmark.seal",
                   detail: "Choose Certificate, then Manage. Add a signing certificate and its matching provisioning profile.")
            method("Using for Free", symbol: "leaf",
                   detail: "Choose Free, then Manage. Pair your iPhone, verify the local connection, and connect your Apple Account.")
        }
        .padding(.horizontal, 22).padding(.vertical, 26)
        .frame(maxWidth: 550, alignment: .leading)
    }

    private func method(_ title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).ipaFont(.headline, weight: .semibold)
            Text(detail).ipaFont(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct IPAIdentityReviewPage: View {
    let review: IPAIdentityReview
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        IPAArtwork(url: review.iconURL, size: 68)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(review.name).ipaFont(.title2, weight: .bold).lineLimit(3)
                            Text("Downloaded app").ipaFont(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Label("Check Before Installing", systemImage: "exclamationmark.shield").ipaFont(.headline, weight: .semibold)
                    Text("The downloaded app’s ID differs from this library’s listing. This can be a catalog mistake or a different app.").ipaFont(.subheadline).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 18) {
                        identifier("Downloaded ID", review.downloadedIdentifier)
                        Divider()
                        identifier("Listed ID", review.listedIdentifier)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 20))
                    Text("Continue only if you recognize the app and trust this library. Its icon comes from the listing and does not verify its identity.").ipaFont(.footnote).foregroundStyle(.secondary)
                    Button { installer.respondToIdentity(true, id: review.id) } label: {
                        Text("Install This App").ipaFont(.headline, weight: .semibold).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    Button("Cancel", role: .cancel) { installer.respondToIdentity(false, id: review.id) }
                        .frame(maxWidth: .infinity).padding(.bottom, 8)
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(IPAStyle.canvas).navigationTitle("Review App").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { installer.respondToIdentity(false, id: review.id) }
                } }
        }.modifier(IPATheme()).presentationDragIndicator(.visible)
    }
    private func identifier(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).ipaFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IPANativeCopyRequest: Identifiable {
    let id = UUID()
    let identifier: String
    let name: String
}


private struct IPANativeCopyPage: View {
    @EnvironmentObject private var index: IPAAllAppsIndex
    private var download: IPAAppVariant? {
        index.entry(identifier: request.identifier)?.variants.first {
            $0.app.bundleIdentifier.caseInsensitiveCompare(request.identifier) == .orderedSame && $0.app.latestVersion != nil
        }
    }
    let request: IPANativeCopyRequest
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(request.name, systemImage: "app.badge.checkmark").font(.title3.bold())
                    Text("Create a separate Home Screen app using your certificate and profile. Your copy inside iPAStore stays here.")
                }
                Section("Your Progress") {
                    Text("iOS keeps each app’s data private. Saves and settings cannot be copied automatically into the native app. Use this app’s cloud save or supported export/import feature to move progress.")
                }
                Section {
                    if let original = IPANativeOriginalCache.available(identifier: request.identifier) {
                        Button("Install Native Copy") { installer.queueNativeCopy(original, identifier: request.identifier) }
                    } else {
                        if let download {
                            Button("Download & Install") { installer.nativeCopy = nil; installer.start(download, independent: true) }
                            Text("Download the original IPA from \(download.store.name) and install it using your certificate.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("The original app is not currently available. Add its library in Stores to enable downloading a native copy.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("Add as an App").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

@MainActor final class IPAFileProgressState: ObservableObject {
    @Published var fraction = 0.0
    @Published var status = "Preparing…"
}
private struct IPAFileProgressView: View {
    @ObservedObject var progress: IPAFileProgressState
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    var body: some View {
        HStack(spacing: 14) {
            ProgressView(value: progress.fraction).progressViewStyle(.circular)
            Text(progress.status).font(.subheadline)
            Spacer()
            Button("Cancel") { installer.cancel() }.disabled(installer.cancelling)
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal).padding(.bottom, 90)
    }
}
