// Simulator-only UI harness. Does not load or execute IPA binaries.
import SwiftUI

@main struct IPAStorePreviewApp: App {
    @StateObject private var model = DataManager.shared.model
    @StateObject private var catalog = AltStoreSourcesViewModel(refreshAllOnLaunch: true)
    @AppStorage("IPAAppearance") private var appearance = "system"
    init() {
        let tabs: [String: LCTabIdentifier] = ["today": .today, "stores": .sources, "apps": .apps, "search": .search, "settings": .settings]
        if let selected = UserDefaults.standard.string(forKey: "IPAPreviewTab"), let tab = tabs[selected] { DataManager.shared.model.selectedTab = tab }
        if ProcessInfo.processInfo.arguments.contains("--verify-catalog") {
            do { try CatalogChecks.run() } catch { fatalError("Catalog checks failed: \(error)") }
        }
    }
    var body: some Scene {
        WindowGroup {
            IPARootTabs()
            .environmentObject(model).environmentObject(catalog)
            .task { if ProcessInfo.processInfo.arguments.contains("--verify-polish") { await PolishChecks.run() } }
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

enum LCTabIdentifier: Hashable { case today, sources, apps, search, settings }
final class SharedModel: ObservableObject {
    @Published var selectedTab: LCTabIdentifier = .today
    @Published var deepLink: URL?
    @Published var apps: [PreviewAppRecord] = []
}
struct PreviewAppRecord { let appInfo: PreviewAppInfo }
struct PreviewAppInfo { func bundleIdentifier() -> String? { nil } }
final class DataManager {
    static let shared = DataManager()
    let model = SharedModel()
}
final class SearchContext: ObservableObject {
    @Published var query = "" { didSet { debouncedQuery = query } }
    @Published var debouncedQuery = ""
}
extension String {
    var loc: String { NSLocalizedString(self, comment: "") }
    func localizeWithFormat(_ arguments: CVarArg...) -> String { String(format: loc, arguments: arguments) }
}
extension NSNotification {
    static let InstallAppNotification = Notification.Name("IPAStorePreviewInstall")
}
struct PreviewAppsView: View {
    @State private var installRequested = false
    @State private var searching = false
    @State private var query = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    IPATabHeading("Apps")
                        .padding(.trailing, 54).frame(maxWidth: .infinity, alignment: .leading)
                    IPACollectionSearchField(query: $query, presented: $searching, belowTabHeading: true)
                }.padding(.horizontal, 20).padding(.top, 8).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .overlay {
                if !searching { IPACollectionEmptyState(symbol: IPAStyle.appsSymbol, message: "Your downloaded apps appear here.") {} }
            }
            .background(IPAStyle.canvas).toolbar(.hidden, for: .navigationBar)
            .ipaCollectionToolbar {
                IPAAppActions(add: { installRequested = true }, refresh: nil,
                              search: { searching = true }, sort: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { _ in installRequested = true }
        .alert("Device Build Required", isPresented: $installRequested) {
            Button("OK", role: .cancel) {}
        } message: { Text("Use the iPhone build to import and run apps.") }
    }
}
struct LCSettingsView: View {
    var body: some View { NavigationView { Form { Section("Interface Preview") { Text("Certificate import and container options are available in the device engine target, not this simulator harness.") } }.navigationTitle("Signing") } }
}
struct LCTweaksView: View {
    var body: some View { Text("Extensions require the device engine build.").padding().navigationTitle("Extensions") }
}

extension Color { func readableTextColor() -> Color { .primary } }
struct BasicButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
