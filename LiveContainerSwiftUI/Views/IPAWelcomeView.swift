import SwiftUI
import UniformTypeIdentifiers

struct IPAWelcomeView: View {
    let close: () -> Void
    @AppStorage("IPAInstallMode") private var mode = "container"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 18) {
                        IPABrandGlyph(size: 76).padding(.top, 24)
                        Text("Welcome to\niPAStore").ipaFont(.largeTitle, weight: .bold).multilineTextAlignment(.center)
                        Text("Your apps. Your choice.").ipaFont(.title3).foregroundStyle(.secondary)
                    }.padding(.bottom, 8)
                    VStack(spacing: 16) {
                        NavigationLink {
                            IPACertificateSetupView(finish: close).onAppear { mode = "independent" }
                        } label: {
                            IPAWelcomeChoice(title: "Use a Certificate", detail: "Install apps directly on your iPhone.", footnote: "Your certificate + provisioning profile", symbol: IPASetupSymbols.certificate, color: .blue)
                        }
                        NavigationLink {
                            IPAWelcomeFreePage(finish: close).onAppear { mode = "container" }
                        } label: {
                            IPAWelcomeChoice(title: "Use for Free", detail: "Keep your apps inside iPAStore.", footnote: "Apple Account · refresh every 7 days", symbol: IPASetupSymbols.free, color: .indigo)
                        }
                    }.buttonStyle(.plain)
                    Button("Set Up Later", action: close).ipaFont(.subheadline).foregroundStyle(.secondary).padding(.vertical, 10)
                    Text("You can return here anytime from Settings.").ipaFont(.caption).foregroundStyle(.tertiary)
                }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }.background(IPAStyle.canvas).navigationBarTitleDisplayMode(.inline)

        }.modifier(IPATheme())
    }
}

private struct IPAWelcomeChoice: View {
    let title: String
    let detail: String
    let footnote: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 28, weight: .medium)).foregroundStyle(color).frame(width: 54, height: 62)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 7) {
                Text(title).ipaFont(.title3, weight: .bold).foregroundStyle(.primary)
                Text(detail).ipaFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(footnote).ipaFont(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(20).frame(maxWidth: .infinity, minHeight: 134, alignment: .leading)
            .background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(color.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 25))
    }
}

private struct IPAWelcomeFreePage: View {
    let finish: () -> Void
    var body: some View { IPAFreeSetupView(finish: finish) }

}

struct IPACertificateSetupView: View {
    var finish: (() -> Void)? = nil
    @StateObject private var state = IPASigningState()
    @ObservedObject private var installation = IPAInstallCoordinator.shared
    @ObservedObject private var renewal = IPARenewalManager.shared
    @State private var importingCertificate = false
    @State private var importingProfile = false
    @State private var removingCertificate: IPAStandaloneCertificates.Entry?
    @State private var renamingCertificate: IPAStandaloneCertificates.Entry?
    @State private var certificateName = ""
    @State private var removingProfile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                IPASetupHeading(symbol: IPASetupSymbols.certificate, title: "Certificates",
                                subtitle: "Choose the certificate and provisioning profile used to install Home Screen apps.")
                IPASettingsGroup(title: "Signing Certificates") {
                    ForEach(state.certificates) { certificate in
                        Button { state.selectCertificate(certificate.id) } label: {
                            HStack {
                                IPASettingsRow(certificate.name, subtitle: certificate.team, symbol: "checkmark.seal", color: .indigo, showsChevron: false)
                                if certificate.id == state.selectedCertificateID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint).padding(.trailing, 16)
                                }
                            }
                        }
                        .accessibilityAddTraits(certificate.id == state.selectedCertificateID ? .isSelected : [])
                        .contextMenu {
                            if certificate.id != IPAStandaloneCertificates.legacyID {
                                Button("Rename", systemImage: "pencil") {
                                    certificateName = certificate.name
                                    renamingCertificate = certificate
                                }
                                Button("Remove Certificate", systemImage: "trash", role: .destructive) {
                                    removingCertificate = certificate
                                }
                            }
                        }
                        IPASettingsDivider()
                    }
                    Button { importingCertificate = true } label: {
                        IPASettingsRow("Add Certificate", subtitle: ".p12 file and password", symbol: "plus.circle.fill", color: .blue)
                    }
                }.disabled(!state.canManageCertificates)

                if !state.certificates.isEmpty {
                    IPASettingsGroup(title: "Provisioning Profile") {
                        Button { importingProfile = true } label: {
                            IPASettingsRow(state.profileSummary == nil ? "Add Profile" : "Replace Profile",
                                           subtitle: state.profileSummary ?? ".mobileprovision file",
                                           symbol: "doc.badge.gearshape", color: .teal)
                        }
                        if state.profileSummary != nil || state.profileProblem != nil {
                            IPASettingsDivider()
                            Button { removingProfile = true } label: {
                                IPASettingsRow("Remove Profile", symbol: "trash", color: .red)
                            }
                        }
                    }.disabled(!state.canManageCertificates)
                }
                if let problem = state.profileProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .ipaFont(.footnote).foregroundStyle(.secondary)
                }
                if let finish {
                    Button(state.standaloneCertificateReady ? "Start Using iPAStore" : "Finish Later", action: finish)
                        .buttonStyle(IPAPillStyle(prominent: true, compact: true))
                        .frame(maxWidth: .infinity)
                }
            }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .background(IPAStyle.canvas).navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $importingCertificate, onDismiss: { state.reload() }) {
            IPACertificateImportView(onSave: { try state.saveCertificate($0, password: $1, filename: $2) })
                .modifier(IPATheme())
        }
        .fileImporter(isPresented: $importingProfile, allowedContentTypes: [UTType(filenameExtension: "mobileprovision") ?? .data]) { result in
            do {
                let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                try state.saveProfile(Data(contentsOf: url))
            } catch { state.message = error.localizedDescription }
        }
        .confirmationDialog("Remove saved signing file?", isPresented: Binding(
            get: { removingCertificate != nil || removingProfile },
            set: { if !$0 { removingCertificate = nil; removingProfile = false } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let certificate = removingCertificate { state.removeSavedCertificate(certificate.id) }
                else if removingProfile { state.removeProfile() }
                removingCertificate = nil
                removingProfile = false
            }
        } message: { Text("You can import the signing file again from its original location.") }
        .onAppear { state.reload() }
        .alert("Rename Certificate", isPresented: Binding(
            get: { renamingCertificate != nil }, set: { if !$0 { renamingCertificate = nil } }
        )) {
            TextField("Name", text: $certificateName)
            Button("Cancel", role: .cancel) { renamingCertificate = nil }
            Button("Save") {
                if let certificate = renamingCertificate { state.renameCertificate(certificate.id, to: certificateName) }
                renamingCertificate = nil
            }.disabled(certificateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Signing Files", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
            Button("OK") { state.message = nil }
        } message: { Text(state.message ?? "") }
    }
}

struct IPASetupHeading: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Environment(\.ipaAccent) private var accent
    var symbolColor: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 46, weight: .light)).foregroundStyle(symbolColor ?? accent)
            Text(title).ipaFont(.largeTitle, weight: .bold)
            Text(subtitle).ipaFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
struct IPASetupStep: View {
    let number: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            Text(number).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(.tint).frame(width: 28, height: 28).background(Color.accentColor.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).ipaFont(.headline); Text(detail).ipaFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct IPASettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.footnote.weight(.semibold)).textCase(nil).foregroundStyle(.secondary).padding(.leading, 6) }
            VStack(spacing: 0, content: content).background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 23)).buttonStyle(.plain)
        }
    }
}
struct IPASettingsDivider: View { var body: some View { Divider().padding(.leading, 68) } }
struct IPASettingsRow: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let color: Color
    var showsChevron: Bool
    init(_ title: String, subtitle: String? = nil, symbol: String, color: Color, showsChevron: Bool = true) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.color = color; self.showsChevron = showsChevron
    }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(color).frame(width: 36, height: 38).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).ipaFont(.body, weight: .medium).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).ipaFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 18).padding(.vertical, 15).contentShape(Rectangle())
    }
}

struct IPAMethodSelector: View {
    @AppStorage("IPAInstallMode") private var mode = "container"
    var body: some View {
        HStack(spacing: 12) {
            method("Certificate", detail: "On your iPhone", symbol: IPASetupSymbols.certificate, value: "independent")
            method("Free", detail: "Inside iPAStore", symbol: IPASetupSymbols.free, value: "container")
        }.padding(12)
    }
    private func method(_ title: String, detail: String, symbol: String, value: String) -> some View {
        Button { mode = value; IPAFeedback.confirmationHaptic() } label: {
            VStack(spacing: 9) {
                HStack { Image(systemName: symbol).font(.title3); Spacer(); Image(systemName: mode == value ? "checkmark.circle.fill" : "circle").font(.subheadline) }
                Text(title).ipaFont(.headline, weight: .semibold).frame(maxWidth: .infinity, alignment: .leading)
                Text(detail).ipaFont(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }.foregroundStyle(mode == value ? Color.accentColor : .secondary).padding(14).frame(maxWidth: .infinity, minHeight: 112)
                .background(mode == value ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(mode == value ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15)))
        }.buttonStyle(.plain).accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}

struct IPASigningHero: View {
    @StateObject private var state = IPASigningState()
    @ObservedObject private var renewal = IPARenewalManager.shared
    @AppStorage("IPAInstallMode") private var mode = "container"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: mode == "container" ? IPASetupSymbols.free : IPASetupSymbols.certificate).font(.system(size: 32, weight: .light)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(mode == "container" ? "Keep iPAStore Ready" : "Certificate Mode").ipaFont(.title2, weight: .bold)
                    if mode == "container", state.freeSetupComplete, let profile = renewal.profile {
                        Text("Expires \(profile.expiresAt.formatted(.relative(presentation: .named)))").ipaFont(.subheadline).foregroundStyle(.secondary)
                    } else { Text(mode == "container" ? "The free way to sign." : "Your apps. On your iPhone.").ipaFont(.subheadline).foregroundStyle(.secondary) }
                }
            }
            HStack(spacing: 12) {
                if mode == "container" { IPASignButton(title: "Sign", compact: true, prominent: true).frame(maxWidth: .infinity) }
                NavigationLink {
                    if mode == "container" { IPAFreeSetupView() } else { IPACertificateSetupView() }
                } label: { IPASetupActionLabel(title: "Manage", symbol: IPASetupSymbols.manage) }
                .buttonStyle(.plain).frame(maxWidth: .infinity)
            }

        }.onAppear { state.importInteractiveReadiness(); state.reload() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in state.reload() }
            .onChange(of: mode) { _, _ in state.reload() }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Color.accentColor.opacity(0.1)))
    }
}

struct IPASigningOptionsView: View {
    @StateObject private var signing = IPASigningState()
    @AppStorage("IPAInstallMode") private var mode = "container"
    private var available: Bool { mode == "independent" && signing.standaloneCertificateReady }
    @AppStorage("IPAEnableFiles") private var files = false
    @AppStorage("IPARemoveExtensions") private var extensions = false
    @AppStorage("IPARemoveWatchApp") private var watch = false
    @AppStorage("IPAUseLegacyAppearance") private var classic = false
    @AppStorage("IPAProMotion") private var promotion = false
    @AppStorage("IPAGameMode") private var gameMode = false
    @AppStorage("IPAIPadFullscreen") private var fullscreen = false
    @AppStorage("IPAArchiveCompression") private var compression = "fast"
    var body: some View {
        Form {
            if !available {
                Section {
                    Label("Full Certificate Required", systemImage: "lock.fill").font(.headline)
                    Text("These options apply to separate iPhone apps. Choose Certificate in Settings and add your .p12 plus a valid matching provisioning profile to unlock them.").foregroundStyle(.secondary)
                }
            }
            Group {
            Section {
                Toggle("Show Documents in Files", isOn: $files)
                Toggle("Enable ProMotion", isOn: $promotion)
                Toggle("Enable Game Mode", isOn: $gameMode)
                Toggle("Full Screen on iPad", isOn: $fullscreen)
            } header: { Text("App Features") } footer: { Text("Requests these features when signing compatible apps. Actual frame rates, Game Mode and layout depend on the app and device.") }
            Section {
                Toggle("Classic App Appearance", isOn: $classic)
                Toggle("Remove App Extensions", isOn: $extensions)
                Toggle("Remove Watch App", isOn: $watch)
            } header: { Text("Compatibility") } footer: { Text("Removing extensions disables their widgets and share actions. These choices apply to new certificate installs; original downloads are kept unchanged.") }
            Section {
                Picker("Compression", selection: $compression) { Text("Fastest").tag("fast"); Text("Smaller Package").tag("small") }
            } header: { Text("Installation Package") } footer: { Text("Fastest uses less processing. Smaller Package compresses the temporary signed IPA before installing.") }
            }.disabled(!available)
        }.onAppear { signing.reload() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in signing.reload() }
            .navigationTitle("Signing Options").navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}

enum IPASetupSymbols {
    static let certificate = "seal.fill"
    static let free = "leaf.circle.fill"
    static let manage = "doc.badge.gearshape"
}
struct IPASetupActionLabel: View {
    @Environment(\.isEnabled) private var enabled
    let title: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 8) { if let symbol { Image(systemName: symbol) }; Text(title).lineLimit(1).minimumScaleFactor(0.8) }
            .ipaFont(.subheadline, weight: .semibold).frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14)).opacity(enabled ? 1 : 0.38)
    }
}

struct IPAHowItWorksView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                IPASetupHeading(symbol: "book.closed.fill", title: "Make yourself at home.", subtitle: "Here’s a little help getting comfortable with iPAStore. Come back whenever you need a hand.", symbolColor: .purple)
                guide("Your apps, your choice", symbol: "square.grid.2x2.fill") {
                    Text("Free keeps your apps together inside iPAStore. Certificate uses your own signing files. You can change your choice in Settings without deleting your apps.")
                    Text("With a .p12 alone, compatible apps can run inside iPAStore after verification. A matching provisioning profile unlocks separate iPhone installations.")
                }
                guide("Come back from a game", symbol: "hand.tap.fill") {
                    Text("Double-tap the lower half of the screen with two fingers. A return button appears near the bottom. Tap it to close the game and return here.")
                    Label("Close & Return to iPAStore", systemImage: "chevron.backward.circle.fill")
                        .font(.subheadline).padding(.vertical, 12).padding(.horizontal, 16)
                        .background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity).padding(.vertical, 8)
                    Text("This illustration matches the return control. Save your progress first—closing a game may lose anything it hasn’t saved. The gesture applies to apps running inside iPAStore; native apps use normal iPhone navigation.").foregroundStyle(.secondary)
                }
                guide("Keep your signature fresh", symbol: "calendar.badge.clock") {
                    Text("A free Apple Account signature usually lasts 7 days. Tap Sign in Settings before it expires. Signing renews iPAStore; your apps and their stored data stay here.")
                    Text("Automatic renewal helps when iOS gives us background time. Keep the local connection available, and check your expiry yourself too. A reminder can give you a friendly nudge.")
                    NavigationLink("Renewal & Reminders") { IPARenewalPreferencesView() }.fontWeight(.semibold)
                }
                guide("A Home Screen app of its own", symbol: "app.badge.checkmark") {
                    Text("Choose Certificate and add both signing files. New installs can then appear as separate apps on your iPhone. They also stay listed in Apps, where Open launches the native app.")
                    Text("To make a native copy of an app already inside iPAStore, press and hold it in Apps, choose Add to Home Screen, then Add as an App. This is available with Certificate selected and a valid matching profile.")
                    Text("Your original copy stays safe. iOS keeps each app’s saves private, so a native copy cannot automatically inherit iPAStore’s saves or settings. Use the game’s cloud save or its supported export/import feature to move progress.")
                }
                guide("Find your next favorite", symbol: "magnifyingglass") {
                    Text("Add a library in Stores, explore its apps, then tap Get. Search stays within reach as you scroll. Today’s featured library opens when you tap anywhere on its card.")
                    Text("If an app needs a different mode, we’ll offer to switch. A Home Screen shortcut to a free app opens through iPAStore; a native installation opens on its own.")
                }
                guide("Make it feel like you", symbol: "paintpalette.fill") {
                    Text("Choose your appearance, accent, icon and sounds in Settings. Signing Options can request Files access, ProMotion, Game Mode and more for compatible apps. App Behavior holds multitasking and advanced tools.")
                    Text("Not every app supports every feature. We’ll keep your choices together and tell you when an app needs extra setup.")
                }
            }.padding(24).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.background(IPAStyle.canvas).navigationTitle("How iPAStore Works").navigationBarTitleDisplayMode(.inline)
    }
    private func guide<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).ipaFont(.title3, weight: .bold)
            VStack(alignment: .leading, spacing: 14, content: content).ipaFont(.subheadline).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 23))
    }
}

struct IPARenewalPreferencesView: View {
    @AppStorage("IPAInstallMode") private var mode = "container"
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = IPASigningState()
    @ObservedObject private var renewal = IPARenewalManager.shared
    private var unlocked: Bool { state.freeSetupComplete && mode == "container" }

    var body: some View {
        Form {
            if !unlocked {
                Section {
                    Label("Complete Free Signing", systemImage: "lock")
                        .ipaFont(.headline)
                    Text("Finish pairing, verify your local connection, and connect your Apple Account in Free setup to unlock these settings.")
                        .ipaFont(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Automatic Renewal", isOn: Binding(get: { renewal.automatic }, set: { renewal.setAutomatic($0) }))
                Toggle("Expiry Reminder", isOn: Binding(get: { renewal.remindersEnabled }, set: { value in Task { await renewal.setReminders(value) } }))
                    .disabled(renewal.updatingReminders)
                if let profile = renewal.profile { LabeledContent("Expires", value: profile.expiresAt.formatted(date: .abbreviated, time: .shortened)) }
                if unlocked, let issue = renewal.reminderIssue { Text(issue).foregroundStyle(.secondary) }
                if unlocked, let issue = renewal.schedulingIssue { Text(issue).foregroundStyle(.secondary) }
            } footer: {
                Text("Automatic renewal checks when you open iPAStore and requests background time before expiry. Background renewal requires your local connection.")
            }
            .disabled(!unlocked)
        }
        .onAppear { state.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { state.reload() } }
        .navigationTitle("Renewal & Reminders").navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}
