// IPAStore account bridge. Authentication and installation stay in the signing service.
import Foundation
import SwiftUI
import Security
import CryptoKit
import UIKit
import UniformTypeIdentifiers

@MainActor
final class IPASigningState: ObservableObject {
    @Published private(set) var serviceAvailable = false
    @Published private(set) var capabilitiesReady = false
    @Published private(set) var accountSaved = false
    @Published private(set) var pairingImported = false
    @Published private(set) var connectionCheckedAt: Date?
    @Published private(set) var containerCertificateAvailable = false
    @Published private(set) var certificateImported = false
    @Published private(set) var certificateProblem: String?
    @Published private(set) var standaloneCertificateReady = false
    @Published private(set) var profileSummary: String?
    @Published private(set) var profileProblem: String?
    var freeSetupComplete: Bool { serviceAvailable && capabilitiesReady && accountSaved && pairingImported && connectionCheckedAt != nil }
    private static var recovery: Task<Void, Never>?
    private static var attemptedRecovery: String?
    private static var attemptedRecoveryAt = Date.distantPast
    static func restoreAfterUpdateIfNeeded() async {
        await Task.yield()
        if let recovery { await recovery.value; return }
        for _ in 0..<200 where verifying && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
        guard !verifying, !IPAInstallCoordinator.shared.busy, !IPARenewalManager.shared.working,
              !UserDefaults.standard.bool(forKey: "IPASigningCertificateRemoved") else { return }
        let state = IPASigningState()
        state.reload()
        guard !verifying else { return }
        #if !IPASTORE_PREVIEW
        let accountOrigin = UserDefaults.standard.string(forKey: "IPACertificateOrigin") == "account"
        if state.freeSetupComplete && (accountOrigin || !state.certificateImported),
           let data = state.readItem("signingCertificate") {
            let password = state.readItem("signingCertificatePassword").flatMap({ String(data: $0, encoding: .utf8) }) ?? ""
            guard LCUtils.getCertTeamId(withKeyData: data, password: password) != nil else { return }
            storeCertificate(data, password: password, origin: "account"); state.reload()
        }
        guard !state.containerCertificateAvailable,
              state.freeSetupComplete || UserDefaults.standard.string(forKey: "IPAVerifiedCertificate") != nil,
              let digest = certificateDigest(), attemptedRecovery != digest || Date().timeIntervalSince(attemptedRecoveryAt) >= 15 else { return }
        attemptedRecovery = digest; attemptedRecoveryAt = Date()
        let task = Task { await state.verifyCertificate(feedback: false) }
        recovery = task; await task.value; recovery = nil
        #endif
    }
    func removeCertificate() {
        #if !IPASTORE_PREVIEW
        guard !busy, !IPAInstallCoordinator.shared.busy, !IPARenewalManager.shared.working else { return }
        for key in ["LCCertificateData", "LCCertificatePassword", "LCCertificateUpdateDate"] {
            LCUtils.appGroupUserDefault.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: key)
        }
        #endif
        for key in ["IPAVerifiedCertificate", "IPACertificateOrigin", "IPACompleteSigningSetup"] { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: "IPASigningCertificateRemoved")
        Self.attemptedRecovery = nil; reload()
    }
    @Published private(set) var certificates: [IPAStandaloneCertificates.Entry] = []
    @Published private(set) var selectedCertificateID = IPAStandaloneCertificates.legacyID

    var canManageCertificates: Bool {
        !busy && !Self.verifying && !IPAInstallCoordinator.shared.busy && !IPARenewalManager.shared.working
    }
    func selectCertificate(_ id: String) {
        guard canManageCertificates, selectedCertificateID != id, certificates.contains(where: { $0.id == id }) else { return }
        IPAStandaloneCertificates.selectedID = id
        reload()
        IPAFeedback.confirmationHaptic()
    }
    func saveCertificate(_ data: Data, password: String, filename: String) throws {
        guard canManageCertificates else { throw IPAStandaloneCertificates.StoreError.busy }
        #if !IPASTORE_PREVIEW
        try IPAStandaloneCertificates.add(data, password: password, filename: filename)
        reload()
        IPAFeedback.confirmationHaptic()
        #endif
    }
    func renameCertificate(_ id: String, to name: String) {
        guard canManageCertificates else { return }
        guard IPAStandaloneCertificates.rename(id, to: name) else { return }
        reload()
        IPAFeedback.confirmationHaptic()
    }
    func removeSavedCertificate(_ id: String) {
        guard canManageCertificates else { return }
        defer { reload() }
        do { try IPAStandaloneCertificates.remove(id); IPAFeedback.confirmationHaptic() }
        catch { message = error.localizedDescription }
    }
    func removeProfile() {
        guard canManageCertificates else { return }
        do { try IPAStandaloneCertificates.removeProfile(for: selectedCertificateID); reload(); IPAFeedback.confirmationHaptic() }
        catch { message = error.localizedDescription }
    }
    func saveProfile(_ data: Data) throws {
        guard canManageCertificates else { throw IPAStandaloneCertificates.StoreError.busy }
        #if !IPASTORE_PREVIEW
        guard let credential = IPAStandaloneCertificates.credential(for: selectedCertificateID) else {
            throw IPAStandaloneCertificates.StoreError.missing
        }
        _ = try LCUtils.standaloneProfileInfo(data, certificate: credential.data, password: credential.password)
        try IPAStandaloneCertificates.saveProfile(data, for: selectedCertificateID)
        reload()
        IPAFeedback.confirmationHaptic()
        #endif
    }
    @Published private(set) var busy = false
    @Published var message: String?

    private static var verifying = false
    private static var capabilitiesCache: Bool?
    static var certificateCheckRunning: Bool { verifying }
    init() { reload() }

    func reload() {
        #if !IPASTORE_PREVIEW
        serviceAvailable = UserDefaults.sideStoreExist()
        if let cached = Self.capabilitiesCache { capabilitiesReady = cached }
        else {
        let task = SecTaskCreateFromSelf(nil)
        let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)?.takeRetainedValue() as? [String] ?? []
        if let team = LCSharedUtils.teamIdentifier() {
            let groupSet = Set(groups)
            let base = "\(team).com.kdt.livecontainer.shared"
            capabilitiesReady = groupSet.contains(base) && (1..<128).allSatisfy { groupSet.contains("\(base).\($0)") }
        } else { capabilitiesReady = false }
            Self.capabilitiesCache = capabilitiesReady
        }
        accountSaved = serviceAvailable && capabilitiesReady && readItem("appleIDEmailAddress") != nil
        let readiness = UserDefaults.standard.dictionary(forKey: "IPASigningReadiness") ?? [:]
        pairingImported = readiness["pairingImported"] as? Bool ?? false
        connectionCheckedAt = readiness["connectionCheckedAt"] as? Date
        if let dates = LCUtils.certificateDates(), let start = dates["notBefore"], let end = dates["notAfter"] {
            certificateImported = true
            let inDate = start <= Date() && end > Date()
            containerCertificateAvailable = inDate && !Self.verifying && Self.certificateDigest() == UserDefaults.standard.string(forKey: "IPAVerifiedCertificate")
            certificateProblem = !inDate ? "This certificate has expired or is not valid yet. Import a current certificate with its private key." : containerCertificateAvailable ? nil : "Verify this certificate on your iPhone before installing or opening apps. A readable certificate may still be rejected by iOS."
        } else {
            certificateImported = false; containerCertificateAvailable = false
            certificateProblem = "Add an Apple Account certificate or import a .p12 file with its password to sign apps inside iPAStore."
        }
        certificates = IPAStandaloneCertificates.entries
        selectedCertificateID = IPAStandaloneCertificates.selectedID
        standaloneCertificateReady = false
        profileSummary = nil
        profileProblem = nil
        if let credential = IPAStandaloneCertificates.credential(for: selectedCertificateID),
           let profile = IPAStandaloneCertificates.profile(for: selectedCertificateID) {
            do {
                let info = try LCUtils.standaloneProfileInfo(profile, certificate: credential.data, password: credential.password)
                let name = info["Name"] as? String ?? "Provisioning Profile"
                if let expiration = info["ExpirationDate"] as? Date {
                    profileSummary = "\(name) · Expires \(expiration.formatted(date: .abbreviated, time: .omitted))"
                } else { profileSummary = name }
                standaloneCertificateReady = true
            } catch { profileProblem = error.localizedDescription }
        }
        #else
        serviceAvailable = false
        capabilitiesReady = false
        accountSaved = false
        pairingImported = false
        connectionCheckedAt = nil
        containerCertificateAvailable = false
        #endif
    }

    func importInteractiveReadiness(allowCertificateImport: Bool = false) {
        #if !IPASTORE_PREVIEW
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let readiness = IPASigningSetupHandoff.consume(hostDocuments: documents) else { return }
        UserDefaults.standard.set(readiness.propertyList, forKey: "IPASigningReadiness")
        if readiness.accountStored && readiness.certificateAvailable && (allowCertificateImport || !UserDefaults.standard.bool(forKey: "IPASigningCertificateRemoved")) { importServiceCertificate(feedback: false) }
        #endif
    }

    static func completePendingSetup() {
        guard UserDefaults.standard.bool(forKey: "IPACompleteSigningSetup") else { return }
        let state = IPASigningState()
        state.importServiceCertificate(feedback: false)
        if state.containerCertificateAvailable { UserDefaults.standard.removeObject(forKey: "IPACompleteSigningSetup") }
    }

    func importServiceCertificate(feedback: Bool = true) {
        #if !IPASTORE_PREVIEW
        guard serviceAvailable, capabilitiesReady, let data = readItem("signingCertificate") else {
            message = "No certificate is available yet. Connect your signing account and sign iPAStore, then try again."
            return
        }
        let password = readItem("signingCertificatePassword").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard LCUtils.getCertTeamId(withKeyData: data, password: password) != nil else {
            message = "The certificate could not be opened. Sign in again and try importing it once more."
            return
        }
        Self.storeCertificate(data, password: password, origin: "account")
        Task { await verifyCertificate(feedback: feedback) }
        #else
        message = "Certificate import requires the device build."
        #endif
    }

    #if !IPASTORE_PREVIEW
    private static func certificateDigest() -> String? {
        guard let data = LCUtils.certificateData() else { return nil }
        var digest = SHA256(); digest.update(data: data)
        if let profile = UserDefaults.lcMainBundle().url(forResource: "embedded", withExtension: "mobileprovision"), let data = try? Data(contentsOf: profile) { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func storeCertificate(_ data: Data, password: String, origin: String) {
        let unchanged = LCUtils.certificateData() == data && LCSharedUtils.certificatePassword() == password
        LCUtils.appGroupUserDefault.set(data, forKey: "LCCertificateData")
        // The launch path also reads the host defaults when no shared suite exists.
        LCUtils.setCertificatePassword(password)
        LCUtils.appGroupUserDefault.set(Date(), forKey: "LCCertificateUpdateDate")
        UserDefaults.standard.set(origin, forKey: "IPACertificateOrigin")
        UserDefaults.standard.removeObject(forKey: "IPASigningCertificateRemoved")
        UserDefaults.standard.set(LCSharedUtils.appGroupID(), forKey: "LCAppGroupID")
        if !unchanged { UserDefaults.standard.removeObject(forKey: "IPAVerifiedCertificate") }
    }
    #endif

    func verifyCertificate(feedback: Bool = true) async {
        guard !busy, !Self.verifying else { return }
        guard !IPAInstallCoordinator.shared.busy, !IPARenewalManager.shared.working else {
            message = "Wait for the current signing or installation to finish before verifying a certificate."; return
        }
        Self.verifying = true
        busy = true; defer { Self.verifying = false; busy = false; reload() }
        #if !IPASTORE_PREVIEW
        guard let dates = LCUtils.certificateDates(), let start = dates["notBefore"], let end = dates["notAfter"], start <= Date(), end > Date(), let digest = Self.certificateDigest() else {
            message = "The certificate is missing, expired or cannot be opened. Import a current .p12 containing its private key and check its password."; return
        }
        let result: (Bool, NSError?) = await withCheckedContinuation { reply in
            LCUtils.validateJITLessSetup { success, error in reply.resume(returning: (success, error as NSError?)) }
        }
        if let error = result.1, error.domain == "iPAStore.Certificate" {
            UserDefaults.standard.removeObject(forKey: "IPAVerifiedCertificate")
            message = error.localizedDescription
            return
        }
        let accepted = result.0
        // Never mark a different certificate ready if it changed during the check.
        if accepted && digest == Self.certificateDigest() {
            UserDefaults.standard.set(digest, forKey: "IPAVerifiedCertificate")
            if feedback { IPAFeedback.success() }
            message = "iOS accepted a test signature. You can now install apps inside iPAStore."
        } else {
            UserDefaults.standard.removeObject(forKey: "IPAVerifiedCertificate")
            message = "iOS did not accept this certificate for apps inside iPAStore. It may be revoked, lack a matching provisioning profile, or belong to a different signing setup. Use the certificate that signed iPAStore, or reinstall iPAStore with your certificate and its matching profile, then verify again. Importing a .p12 alone does not authorize apps to run."
        }
        #else
        message = "Certificate verification requires the iPhone build."
        #endif
    }

    #if !IPASTORE_PREVIEW
    private func readItem(_ account: String) -> Data? {
        // Same namespace as the embedded service's dynamically selected host identity.
        let service = UserDefaults.lcMainBundle().bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "app.ipastore.IPAStore"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    #endif
}

struct IPACertificateImportView: View {
    let onImport: () -> Void
    var onSave: ((Data, String, String) throws -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var data: Data?
    @State private var filename = "No File Selected"
    @State private var password = ""
    @State private var failure: String?
    @FocusState private var passwordFocused: Bool
    init(initialData: Data? = nil, onSave: ((Data, String, String) throws -> Void)? = nil, onImport: @escaping () -> Void = {}) {
        self.onSave = onSave
        self.onImport = onImport
        _data = State(initialValue: initialData)
        _filename = State(initialValue: initialData == nil ? "No File Selected" : "Imported Certificate.p12")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(filename) { choosing = true }
                    SecureField("Certificate Password", text: $password).focused($passwordFocused).textContentType(.password)
                } header: { Text("Certificate") } footer: {
                    if onSave == nil { Text("Choose the .p12 containing the private key used to sign iPAStore.") }
                    else { Text("Choose a .p12 containing its private key. Add its matching provisioning profile after importing.") }
                }
                if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
            }.navigationTitle("Add Certificate").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { save() }.disabled(data == nil) }
            }
            .onAppear { passwordFocused = data != nil }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    data = try Data(contentsOf: url)
                    filename = url.lastPathComponent
                    failure = nil; passwordFocused = true
                } catch { failure = error.localizedDescription.ipaDisplayMessage }
            }
        }
    }
    private func save() {
        #if !IPASTORE_PREVIEW
        guard let data, LCUtils.getCertTeamId(withKeyData: data, password: password) != nil else {
            failure = "Unable to open the certificate. Check the file and password."
            return
        }
        do {
            if let onSave { try onSave(data, password, filename) }
            else { IPASigningState.storeCertificate(data, password: password, origin: "file") }
        } catch {
            failure = error.localizedDescription
            return
        }
        onImport()
        dismiss()
        #else
        failure = "Certificate import is available on your iPhone."
        #endif
    }
}


@MainActor enum IPAStandaloneCertificates {
    struct Entry: Codable, Identifiable {
        let id: String
        var name: String
        let team: String?
    }
    struct Credential: Codable {
        let data: Data
        let password: String
    }
    enum StoreError: LocalizedError {
        case busy, missing, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .busy: "Wait for signing or installation to finish."
            case .missing: "Select a certificate before adding its provisioning profile."
            case .keychain(let status):
                SecCopyErrorMessageString(status, nil) as String? ?? "The certificate couldn’t be saved securely."
            }
        }
    }

    static let legacyID = "existing"
    private static let listKey = "IPAStandaloneCertificateList"
    private static let selectionKey = "IPAStandaloneCertificateSelection"
    private static let service = "\(Bundle.main.bundleIdentifier ?? "app.ipastore.IPAStore").standalone-certificates"
    private static var imported: [Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: listKey) else { return [] }
            return (try? PropertyListDecoder().decode([Entry].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? PropertyListEncoder().encode(newValue), forKey: listKey) }
    }
    static var entries: [Entry] {
        let saved = imported
        guard credential(for: legacyID) != nil else { return saved }
        return [Entry(id: legacyID, name: "Existing Certificate", team: nil)] + saved
    }
    static var selectedID: String {
        get {
            if let value = UserDefaults.standard.string(forKey: selectionKey),
               (value == legacyID ? credential(for: legacyID) != nil : imported.contains(where: { $0.id == value })) { return value }
            return credential(for: legacyID) != nil ? legacyID : imported.first?.id ?? legacyID
        }
        set { UserDefaults.standard.set(newValue, forKey: selectionKey) }
    }
    static func credential(for id: String) -> Credential? {
        if id == legacyID {
            #if !IPASTORE_PREVIEW
            guard let data = LCUtils.certificateData() else { return nil }
            return Credential(data: data, password: LCSharedUtils.certificatePassword() ?? "")
            #else
            return nil
            #endif
        }
        var query = item(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? PropertyListDecoder().decode(Credential.self, from: data)
    }
    #if !IPASTORE_PREVIEW
    static func add(_ data: Data, password: String, filename: String) throws {
        guard let team = LCUtils.getCertTeamId(withKeyData: data, password: password) else { throw StoreError.missing }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if !imported.contains(where: { $0.id == id }) {
            var query = item(id)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecValueData as String] = try PropertyListEncoder().encode(Credential(data: data, password: password))
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw StoreError.keychain(status) }
            let name = (filename as NSString).deletingPathExtension
            imported.append(Entry(id: id, name: name.isEmpty ? "Certificate" : name, team: team))
        }
        selectedID = id
    }
    #endif
    static func rename(_ id: String, to name: String) -> Bool {
        let normalized = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        var saved = imported
        guard !normalized.isEmpty, let index = saved.firstIndex(where: { $0.id == id }),
              saved[index].name != normalized else { return false }
        saved[index].name = normalized
        imported = saved
        return true
    }
    static func remove(_ id: String) throws {
        guard id != legacyID else { return }
        let status = SecItemDelete(item(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
        imported.removeAll { $0.id == id }
        try removeProfile(for: id)
    }
    static func profile(for id: String) -> Data? { try? Data(contentsOf: profileURL(id)) }
    static func saveProfile(_ data: Data, for id: String) throws {
        let url = profileURL(id)
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func removeProfile(for id: String) throws {
        do { try FileManager.default.removeItem(at: profileURL(id)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
    private static func profileURL(_ id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Signing", isDirectory: true)
            .appendingPathComponent(id == legacyID ? "Standalone.mobileprovision" : "\(id).mobileprovision")
    }
    private static func item(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
}
