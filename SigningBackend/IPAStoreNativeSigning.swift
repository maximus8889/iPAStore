// IPAStore native setup. Compiled into the pinned signing engine, not its storefront.
// Existing pairing, authentication and installation implementations retain their licenses.
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Minimuxer
import UserNotifications
import AudioToolbox

@available(iOS 17.0, *)
@MainActor
@objc(IPAStoreSigningController)
final class IPAStoreSigningController: NSObject {
    @objc(controllerWithAppearance:returnHandler:)
    static func controller(appearance: String, returnHandler: @escaping () -> Void) -> UIViewController {
        let state = IPAStoreNativeSigningState()
        let accent = signingTint
        let root = IPAStoreNativeSigningView(state: state, done: returnHandler, accent: accent)
            .tint(accent).accentColor(accent)
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        let controller = UIHostingController(rootView: root)
        controller.view.tintColor = UIColor(accent)
        state.presenter = controller
        return controller
    }
    private static var signingTint: Color {
        let hex = ProcessInfo.processInfo.environment["IPA_SIGNING_ACCENT"] ?? "007AFF"
        if hex == "systemBlue" || hex.uppercased() == "007AFF" { return Color(uiColor: .systemBlue) }
        let value = UInt32(hex, radix: 16) ?? 0x007AFF
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    @objc static func setupStatus() -> NSDictionary {
        ["pairingImported": PairingFileManager.shared.hasPairingFile(),
         "accountStored": AuthManager.shared.isAuthenticated,
         "certificateAvailable": Keychain.shared.signingCertificate != nil,
         "connectionCheckedAt": UserDefaults.standard.object(forKey: "IPAStoreConnectionCheckedAt") ?? NSNull()]
    }
}

@available(iOS 17.0, *)
@MainActor
private final class IPAStoreNativeSigningState: ObservableObject {
    @Published var initialized = false
    @Published var pairingImported = false
    @Published var accountStored = false
    @Published var connectionVerified = false
    @Published var busy = false
    @Published var message: String?
    @Published var installing = false
    @Published var installationMessage: String?
    @Published var pairingRunning = false
    @Published var pairingCode: String?
    @Published var pairingStatus: String?
    private var feedbackSound: SystemSoundID = 0
    private func stepCompleted() {
        guard UIApplication.shared.applicationState == .active else { return }
        if ProcessInfo.processInfo.environment["IPA_SIGNING_HAPTICS"] != "0" { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        guard ProcessInfo.processInfo.environment["IPA_SIGNING_SOUNDS"] != "0" else { return }
        if feedbackSound == 0, let file = Bundle.main.url(forResource: "Success", withExtension: "wav") { AudioServicesCreateSystemSoundID(file as CFURL, &feedbackSound) }
        if feedbackSound != 0 { AudioServicesPlaySystemSound(feedbackSound) }
    }
    deinit { if feedbackSound != 0 { AudioServicesDisposeSystemSoundID(feedbackSound) } }
    private var pairingGeneration = UUID()
    private var pairingBackground: UIBackgroundTaskIdentifier = .invalid
    private var pairingDirectory: URL?
    weak var presenter: UIViewController?
    private var pendingInstallation: URL?

    func prepare() async {
        do {
            try await DatabaseManager.shared.start()
            initialized = true
            reload()
            // The host owns renewal scheduling. Never enable hidden keep-alive services here.
            UserDefaults.standard.isBackgroundRefreshEnabled = false
        } catch { message = "Signing couldn’t start. Please return to iPAStore and try again." }
    }
    func reload() {
        pairingImported = PairingFileManager.shared.hasPairingFile()
        accountStored = AuthManager.shared.isAuthenticated
        if !pairingImported { connectionVerified = false }
    }
    // Returns true when a certificate must be opened by the host password screen.
    func importPairing(_ url: URL) -> Bool {
        if ["p12", "pfx"].contains(url.pathExtension.lowercased()) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: url)
                guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("IPAStoreCertificateImport.p12")
                try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return true
            } catch { message = "The certificate couldn’t be read. Return to Signing & Refresh and choose Import .p12 Certificate."; return false }
        }
        do {
            try PairingFileManager.shared.importPairingFile(from: url)
            if let mode = PairingFileManager.shared.persistedActiveProtocol {
                let file = PairingFileManager.shared.pairingFileURL(for: mode)
                try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            }
            connectionVerified = false
            UserDefaults.standard.removeObject(forKey: "IPAStoreConnectionCheckedAt")
            reload(); stepCompleted()
        } catch { message = "This pairing file couldn’t be imported. Choose a .plist or .mobiledevicepairing record exported for this iPhone. A .p12 is a signing certificate; import it in Signing & Refresh instead." }
        return false
    }
    func verifyConnection() async {
        guard !busy else { return }
        guard initialized else { await prepare(); if !initialized { return }; await verifyConnection(); return }
        guard let pairing = PairingFileManager.shared.fetchPairingFile() else { message = "Pair this iPhone in step 1 first."; return }
        busy = true; defer { busy = false }
        do {
            try await AppBootManager.shared.startMinimuxer(pairingFile: pairing)
            _ = try await fetchUDID(forceLive: true)
            connectionVerified = true
            stepCompleted()
            UserDefaults.standard.set(Date(), forKey: "IPAStoreConnectionCheckedAt")
        } catch {
            connectionVerified = false
            UserDefaults.standard.removeObject(forKey: "IPAStoreConnectionCheckedAt")
            message = "The iPhone connection couldn’t be verified. Enable the local connection helper, connect to Wi-Fi, and try again. If it still fails, pair this iPhone again in step 1."
        }
    }
    func pairThisIPhone() async {
        guard !busy, !pairingRunning else { return }
        guard #available(iOS 27.0, *) else { message = "Pairing on this iPhone requires iOS 27 or later. If you already have a pairing file, use Import Existing Pairing."; return }
        if !initialized { await prepare(); guard initialized else { return } }
        let notifications = UNUserNotificationCenter.current()
        _ = try? await notifications.requestAuthorization(options: [.alert])
        let token = UUID(); pairingGeneration = token
        pairingRunning = true; busy = true; pairingCode = nil
        pairingStatus = "Preparing this iPhone’s pairing connection…"
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IPAStorePairing-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
            pairingDirectory = folder
            pairingBackground = UIApplication.shared.beginBackgroundTask(withName: "iPAStore Pairing") { [weak self] in
                Task { @MainActor in self?.cancelPairing(reason: "Pairing paused when iOS ended background time. Return to iPAStore and try again.") }
            }
            minimuxer.wirelessPair.onReadyToPair = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.pairingRunning, self.pairingGeneration == token else { return }
                    self.pairingStatus = "Open Settings → Privacy & Security → Developer Mode → Pair with iPAStore. Enter the code when iOS asks."
                }
            }
            minimuxer.wirelessPair.onPinReceived = { [weak self] pin in
                Task { @MainActor in
                    guard let self, self.pairingRunning, self.pairingGeneration == token else { return }
                    self.pairingCode = pin
                    let content = UNMutableNotificationContent()
                    content.title = "iPAStore Pairing Code"
                    content.body = pin
                    content.interruptionLevel = .timeSensitive
                    try? await notifications.add(UNNotificationRequest(identifier: "IPAStorePairingCode", content: content, trigger: nil))
                }
            }
            minimuxer.wirelessPair.start(hostName: "iPAStore", hostModel: "Mac17,7", outPath: folder.path, resolveFileName: { _, _ in "ThisIPhone.plist" }) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.pairingRunning, self.pairingGeneration == token else { return }
                    switch result {
                    case .success(let record):
                        do {
                            let file = URL(fileURLWithPath: record.pairingFilePath).standardizedFileURL
                            guard file.deletingLastPathComponent() == folder.standardizedFileURL else { throw CocoaError(.fileReadInvalidFileName) }
                            try PairingFileManager.shared.importPairingFile(from: file)
                            self.finishPairing()
                            self.reload(); self.stepCompleted()
                            self.pairingStatus = "This iPhone is paired. Continue with the local connection below."
                        } catch { self.cancelPairing(reason: "The pairing could not be saved. Try pairing this iPhone again.") }
                    case .failure:
                        self.cancelPairing(reason: "Pairing did not finish. Keep Wi-Fi and Developer Mode on, then try again.")
                    }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard let self, self.pairingGeneration == token, self.pairingRunning else { return }
                self.cancelPairing(reason: "Pairing timed out. Return here and tap Pair This iPhone to try again.")
            }
        } catch { cancelPairing(reason: "Pairing could not start. Check available storage and try again.") }
    }
    func cancelPairing(reason: String? = nil) {
        guard pairingRunning else { return }
        pairingGeneration = UUID()
        minimuxer.wirelessPair.onReadyToPair = nil
        minimuxer.wirelessPair.onPinReceived = nil
        minimuxer.wirelessPair.stop()
        finishPairing()
        pairingStatus = reason
    }
    private func finishPairing() {
        pairingRunning = false; busy = false; pairingCode = nil
        pairingGeneration = UUID()
        minimuxer.wirelessPair.onReadyToPair = nil
        minimuxer.wirelessPair.onPinReceived = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["IPAStorePairingCode"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["IPAStorePairingCode"])
        if pairingBackground != .invalid { UIApplication.shared.endBackgroundTask(pairingBackground); pairingBackground = .invalid }
        if let folder = pairingDirectory { try? FileManager.default.removeItem(at: folder) }; pairingDirectory = nil
    }
    func signIn() async {
        guard !busy else { return }
        guard initialized else { await prepare(); if !initialized { return }; await signIn(); return }
        guard pairingImported else { message = "First pair this iPhone in step 1. To use a .p12 certificate instead, return to Settings and choose Certificate."; return }
        guard connectionVerified else { message = "Enable the local connection, then tap Verify Connection in step 2 before connecting your Apple Account."; return }
        guard let presenter else { message = "The account screen couldn’t open. Go back and reopen Signing Setup."; return }
        busy = true; defer { busy = false }
        do {
            _ = try await AuthManager.shared.signIn(presentingViewController: presenter, skipResign: true, skipHowTos: true)
            reload(); stepCompleted()
        } catch {
            if !(error is CancellationError) { message = IPAAccountSignInFailure(error).message }
        }
    }
    func finishSetup(_ done: () -> Void) {
        if pairingImported && connectionVerified && accountStored { stepCompleted() }
        done()
    }
    func receiveInstallation(_ notification: Notification) {
        guard let url = notification.userInfo?[AppDelegate.importAppDeepLinkURLKey] as? URL else { return }
        pendingInstallation = url
    }
    func installPending() {
        guard let url = pendingInstallation, initialized, !installing, let presenter else { return }
        pendingInstallation = nil
        InstallAppDialog.present(ipaURL: url, from: presenter, onConfirm: { [weak self] in
            guard let self else { return }
            self.installing = true
            self.installationMessage = "Installing app…"
            AppManager.shared.install(.url(url), presentingViewController: presenter) { [weak self] result in
                Task { @MainActor in
                    self?.installing = false
                    switch result {
                    case .success:
                        self?.installationMessage = "The app was installed on your iPhone."
                        self?.stepCompleted()
                    case .failure(let error): self?.message = error.localizedDescription
                    }
                }
            }
        }, onCancel: {})
    }
}

@available(iOS 17.0, *)
private struct IPAStoreNativeSigningView: View {
    @ObservedObject var state: IPAStoreNativeSigningState
    let done: () -> Void
    let accent: Color
    @State private var choosingPairing = false
    @State private var returningCertificate = false
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "leaf.circle.fill").font(.system(size: 48, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("Free Signing").font(.largeTitle.bold())
                        Text("Pair this iPhone, connect locally, then sign in with your Apple Account. Your apps stay inside iPAStore.")
                            .font(.body).foregroundStyle(.secondary)
                    }.padding(.bottom, 8)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 4, trailing: 18))
                .listRowBackground(Color.clear)
                Section {
                    step("Pair This iPhone", subtitle: state.pairingImported ? "Ready" : "Set up directly on this iPhone.", symbol: "iphone.and.arrow.forward", complete: state.pairingImported)
                    SwiftUI.Button(state.pairingImported ? "Pair Again" : "Pair This iPhone") { Task { await state.pairThisIPhone() } }.disabled(state.busy)
                    if state.pairingRunning {
                        if let code = state.pairingCode {
                            Text(code).font(.system(size: 32, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Text("Enter this code in the pairing prompt in Settings.").font(.footnote).foregroundStyle(.secondary)
                        }
                        SwiftUI.Button("Cancel Pairing", role: .cancel) { state.cancelPairing() }
                    }
                    if let status = state.pairingStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    DisclosureGroup("Already have a pairing file?") {
                        SwiftUI.Button("Import Existing Pairing") { choosingPairing = true }.disabled(state.busy)
                    }
                } header: { Text("1 · Pairing") }
                Section {
                    step("Local Connection", subtitle: state.connectionVerified ? "Connection verified" : "A local VPN lets signing communicate with your iPhone.", symbol: "network", complete: state.connectionVerified)
                    Link("Get Connection Helper", destination: URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!)
                    SwiftUI.Button("Connect Local Tunnel") {
                        openURL(URL(string: "localdevvpn://")!) { accepted in
                            if !accepted { state.message = "iOS couldn’t open the connection helper. Use Get Connection Helper to install it, open it from your Home Screen and tap Connect, then return here." }
                        }
                    }
                    SwiftUI.Button("Verify Connection") { Task { await state.verifyConnection() } }.disabled(state.busy)
                } header: { Text("2 · Connection") }
                Section {
                    step("Signing Account", subtitle: state.accountStored ? "Account saved" : "Your Apple Account provides the certificate used to sign apps.", symbol: "person.crop.circle.badge.checkmark", complete: state.accountStored)
                    SwiftUI.Button(state.accountStored ? "Verify Signing Account" : "Connect Apple Account") { Task { await state.signIn() } }.disabled(state.busy)
                } header: { Text("3 · Account") } footer: { Text("iPAStore will use this account’s certificate to prepare imported apps when you finish setup. Account and device limits apply.") }
                if state.busy { Section { HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) } } }
                if let message = state.installationMessage { Section { Text(message) } }
            }
            .contentMargins(.top, 6, for: .scrollContent)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SwiftUI.Button("Done") { state.finishSetup(done) }.disabled(state.busy || state.installing)
                }
            }
            .task { await state.prepare(); state.installPending() }
            .onDisappear { state.cancelPairing() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in state.reload() }
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.importAppDeepLinkNotification)) { notification in state.receiveInstallation(notification); state.installPending() }
            .fileImporter(isPresented: $choosingPairing, allowedContentTypes: PairingFileManager.supportedContentTypes + [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { returningCertificate = state.importPairing(url) }
                case .failure(let error): if !(error is CancellationError) { state.message = "No pairing file was imported. Please try again." }
                }
            }
            .onChange(of: choosingPairing) { _, choosing in
                if !choosing && returningCertificate { returningCertificate = false; done() }
            }
            .onChange(of: returningCertificate) { _, returning in
                if returning && !choosingPairing { returningCertificate = false; done() }
            }
            .sheet(isPresented: Binding(get: { state.message != nil && !choosingPairing }, set: { if !$0 { state.message = nil } })) {
                NavigationStack {
                    Form {
                        Section { Label("Signing Needs Attention", systemImage: "exclamationmark.circle").font(.title3.bold()); Text(state.message ?? "") }
                        Section("Next Steps") {
                            Text("1. Tap Pair This iPhone and approve pairing in iOS Settings.")
                            Text("2. Enable the local connection and tap Verify Connection.")
                            Text("3. Connect your Apple Account. Finish any verification Apple requests, then tap Done.")
                        }
                    }.navigationTitle("Help & Recovery").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { SwiftUI.Button("Done") { state.message = nil } } }
                }
            }
        }
    }
    private func step(_ title: String, subtitle: String, symbol: String, complete: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: complete ? "checkmark.circle.fill" : symbol).font(.title3).foregroundStyle(complete ? Color.green : accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}

// Direct worker for host-initiated renewal. No AppIntent foreground-continuation deadline.
@available(iOS 17.0, *)
@MainActor
@objc(IPAStoreSigningTask)
private final class IPAStoreSigningTask: NSObject {
    private let gate = IPAResultGate<Void>()
    private var worker: Task<Void, Never>?
    private var cancelOperation: (() -> Void)?
    func begin(progress: Progress, completion: @escaping (NSError?) -> Void) {
        worker = Task {
            do {
                try Task.checkCancellation()
                try await DatabaseManager.shared.start()
                guard AuthManager.shared.isAuthenticated else { throw OperationError.notAuthenticated }
                guard let pairing = PairingFileManager.shared.fetchPairingFile() else {
                    throw NSError(domain: "IPAStore.Signing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Import your iPhone’s pairing file in Signing Setup."])
                }
                try await AppBootManager.shared.startMinimuxer(pairingFile: pairing)
                try Task.checkCancellation()
                let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
                let apps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
                guard !apps.isEmpty else {
                    throw NSError(domain: "IPAStore.Signing", code: 2, userInfo: [NSLocalizedDescriptionKey: "No signed apps are registered for renewal. Complete Signing Setup and try again."])
                }
                do {
                    let operation = try AppManager.shared.backgroundRefresh(apps, presentsNotifications: false) { [gate] result in
                        do {
                            let results = try result.get()
                            guard let hostResult = results[StoreApp.altstoreAppID] else {
                                throw NSError(domain: "IPAStore.Signing", code: 3, userInfo: [NSLocalizedDescriptionKey: "iPAStore was not included in the completed renewal. Close other running signing tasks, check your setup and try Sign iPAStore Now again."])
                            }
                            _ = try hostResult.get()
                            for (_, outcome) in results { _ = try outcome.get() }
                            gate.finish(.success(()))
                        } catch { gate.finish(.failure(error)) }
                    }
                    operation.ignoresServerNotFoundError = false
                    cancelOperation = { operation.cancel() }
                    progress.addChild(operation.progress, withPendingUnitCount: 100)
                } catch { gate.finish(.failure(error)) }
                try await gate.wait()
                completion(nil)
            } catch { completion(error as NSError) }
            cancelOperation = nil
            worker = nil
        }
    }
    @objc nonisolated func cancel() {
        Task { @MainActor in
            self.worker?.cancel()
            // Wait for the underlying engine's completion before releasing the
            // shared signing lease. Cancellation is cooperative.
            self.cancelOperation?()
        }
    }
}

@available(iOS 17.0, *)
extension IPAStoreSigningController {
    @objc(startRefreshWithProgress:completion:)
    static func startRefresh(progress: Progress, completion: @escaping (NSError?) -> Void) -> NSObject {
        let task = IPAStoreSigningTask()
        task.begin(progress: progress, completion: completion)
        return task
    }
}

// Independent installs use the same serialized host worker as renewal. The host
// has already safely unpacked and inspected this private app directory.
@available(iOS 17.0, *)
@MainActor
private final class IPAStoreInstallationTask: NSObject {
    private let gate = IPAResultGate<[String: String]>()
    private var worker: Task<Void, Never>?
    private var cancelOperation: (() -> Void)?
    func begin(request: [String: String], progress: Progress, completion: @escaping (NSDictionary?, NSError?) -> Void) {
        worker = Task {
            do {
                try Task.checkCancellation()
                try await DatabaseManager.shared.start()
                guard AuthManager.shared.isAuthenticated else { throw OperationError.notAuthenticated }
                guard let pairing = PairingFileManager.shared.fetchPairingFile() else {
                    throw Self.problem("Import your iPhone’s pairing file in Signing & Refresh.")
                }
                try await AppBootManager.shared.startMinimuxer(pairingFile: pairing)
                _ = try await fetchUDID(forceLive: true)
                let team = try await AuthManager.shared.getAuthenticatedTeam()
                guard team.type == .individual || team.type == .organization else {
                    throw Self.problem("Independent installation in iPAStore requires a paid developer account. Choose Apps in iPAStore in Settings to use the container mode with a free account.")
                }
                try Task.checkCancellation()
                if request["task"] == "prepareInstall" {
                    progress.completedUnitCount = progress.totalUnitCount
                    completion(["ready": "true"], nil)
                } else if request["task"] == "install", let path = request["path"], let expectedID = request["identifier"] {
                    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("IPAStoreIncoming", isDirectory: true).resolvingSymlinksInPath()
                    let file = URL(fileURLWithPath: path).standardizedFileURL
                    guard file.deletingLastPathComponent() == root, file.pathExtension == "app",
                          UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                          let bundle = Bundle(url: file), bundle.bundleIdentifier == expectedID else {
                        throw Self.problem("This installation package couldn’t be verified. Download it again from its library.")
                    }
                    UserDefaults.standard.isAutoLaunchAppAfterInstallEnabled = false
                    let operation = AppManager.shared.install(.url(file), presentingViewController: nil) { [gate] result in
                        switch result {
                        case .failure(let error): gate.finish(.failure(error))
                        case .success(let app):
                            guard let context = app.managedObjectContext else { gate.finish(.failure(Self.problem("The installation result is unavailable. Check the Home Screen before trying again."))); return }
                            context.perform {
                                gate.finish(.success(["identifier": app.bundleIdentifier, "resignedIdentifier": app.resignedBundleIdentifier, "openURL": app.openAppURL.absoluteString, "name": app.name]))
                            }
                        }
                    }
                    cancelOperation = { operation.cancel() }
                    progress.addChild(operation.progress, withPendingUnitCount: 100)
                    let result = try await gate.wait()
                    completion(result as NSDictionary, nil)
                } else { throw Self.problem("This signing request is unsupported. Install a matching iPAStore update.") }
            } catch { completion(nil, error as NSError) }
            cancelOperation = nil; worker = nil
        }
    }
    @objc nonisolated func cancel() {
        Task { @MainActor in self.worker?.cancel(); self.cancelOperation?() }
    }
    nonisolated private static func problem(_ message: String) -> NSError { NSError(domain: "IPAStore.Installation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@available(iOS 17.0, *)
extension IPAStoreSigningController {
    @objc(startTaskWithRequest:progress:completion:)
    static func startTask(request: [String: String], progress: Progress, completion: @escaping (NSDictionary?, NSError?) -> Void) -> NSObject {
        let task = IPAStoreInstallationTask()
        task.begin(request: request, progress: progress, completion: completion)
        return task
    }
}
