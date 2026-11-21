//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @ObservedObject private var guestSession = IPAAppSession.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    @State private var forgetting: IPAIndependentApp?
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false
    @State private var sortingApps = false
    @State private var showingUpdates = false
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @EnvironmentObject private var discovery: IPADiscovery
    @EnvironmentObject private var catalogIndex: IPAAllAppsIndex
    @ObservedObject private var activity = IPAActivityHistory.shared
    @AppStorage("IPAInstalledAppSubtitle") private var subtitle = IPAAppSubtitle.none
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false
    
    @StateObject private var searchContext = SearchContext()
    @State private var collectionSearch = false
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    init() {
        _installOptions = State(initialValue: [])
    }
    
    private func subtitleText(for app: LCAppModel) -> String? {
        subtitleText(identifier: app.appInfo.bundleIdentifier(), version: app.version)
    }

    private func subtitleText(identifier: String?, version: String?) -> String? {
        switch subtitle {
        case .none: return nil
        case .version: return version.map { "Version \($0)" }
        case .description:
            guard let identifier, let entry = catalogIndex.entry(identifier: identifier) else { return nil }
            let variant = entry.variants.first { $0.app.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame }
            return IPACatalogPresentation.displayValue(variant?.app.subtitle)
                ?? IPACatalogPresentation.displayValue(variant?.app.description)
        }
    }

    @ViewBuilder private func updateButton(_ update: IPAInstalledAppUpdate) -> some View {
        if installer.job(for: update.variant, independent: update.independent) == nil {
            Button("Update") { installer.start(update.variant, independent: update.independent) }
                .buttonStyle(IPAPillStyle(prominent: true, compact: true))
                .accessibilityLabel("Update \(update.variant.app.name)")
        }
    }

    var body: some View {
        let updates = Dictionary(IPAInstalledAppUpdate.matches(
            apps: sortedApps.filter { !$0.uiIsHidden && !$0.uiIsLocked },
            independentApps: installer.independentApps, index: catalogIndex, history: activity.downloads
        ).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        IPATabHeading("Apps")
                            .padding(.trailing, 52).frame(maxWidth: .infinity, alignment: .leading)
                        if let failed = installer.jobs.first(where: { $0.failure != nil }) {
                            Button { installer.showFailure(failed.id) } label: {
                                Label("Some apps need attention", systemImage: "exclamationmark.circle")
                                    .ipaFont(.subheadline).foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        } else {
                            let count = sortedApps.count + (sharedModel.isHiddenAppUnlocked ? sortedHiddenApps.count : 0) + installer.independentApps.count
                            if count > 0 {
                                Text(count == 1 ? "1 app" : "\(count) apps")
                                    .ipaFont(.subheadline).foregroundStyle(.secondary)
                                    .onTapGesture(count: 3) { Task { await authenticateUser() } }
                            }
                        }
                        if installprogressVisible {
                            ProgressView().accessibilityLabel("Importing app")
                        }
                    }
                    if sharedModel.multiLCStatus != 2, !collectionSearch,
                       !sortedApps.isEmpty || (sharedModel.isHiddenAppUnlocked && !sortedHiddenApps.isEmpty) {
                        IPAArrangeCollectionButton("Arrange Apps") { customSortViewPresent = true }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 20).padding(.top, 8).frame(maxWidth: 760).frame(maxWidth: .infinity)
                NavigationLink(
                    destination: navigateTo.map { $0.ipaNativePage() },
                    isActive: $isNavigationActive,
                    label: {
                        EmptyView()
                })
                .hidden()
                
                if let record = guestSession.interruptedRecord {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Continue \(record.name)", systemImage: "arrow.counterclockwise.circle").ipaFont(.headline)
                            Spacer()
                            Button { guestSession.dismissInterruptedRecord() } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss previous session")
                        }
                        Text("The previous process ended while you were away. Reopen to continue; an unsaved round may restart.").ipaFont(.subheadline).foregroundStyle(.secondary)
                        Button("Open") { Task { await guestSession.continueInterruptedSession() } }.buttonStyle(IPAPillStyle())
                    }.padding(16).background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 20).padding(.bottom, 12)
                }
                LazyVStack(spacing: 4) {
                    ForEach(installer.jobs.filter { searchContext.debouncedQuery.isEmpty || $0.variant.app.name.localizedCaseInsensitiveContains(searchContext.debouncedQuery) }) { job in
                        IPAInstallationJobRow(job: job)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                }.padding(.horizontal, 20).padding(.top, installer.jobs.isEmpty ? 0 : 8)
                    .animation(reduceMotion ? nil : IPAMotion.state(reduced: false), value: installer.jobs.map(\.id))
                
                LazyVStack {
                    ForEach(filteredApps, id: \.self) { app in
                        HStack(spacing: 8) {
                            LCAppBanner(appModel: app, delegate: self, subtitle: subtitleText(for: app))
                            if let identifier = app.appInfo.bundleIdentifier(),
                               let update = updates[IPAInstalledAppUpdate.id(identifier, independent: false)] {
                                updateButton(update)
                            }
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
                .padding()
                .animation(searchContext.isTyping || reduceMotion ? nil : IPAMotion.state(reduced: false), value: filteredApps)

                if !installer.independentApps.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("On Your iPhone").font(.title2.bold())
                        ForEach(installer.independentApps.filter { searchContext.debouncedQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(searchContext.debouncedQuery) }) { app in
                            HStack {
                                Image(systemName: "app.badge.checkmark").font(.title2).foregroundStyle(.tint).frame(width: 52, height: 52).background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).ipaFont(.headline)
                                    if let text = subtitleText(identifier: app.identifier, version: app.version) {
                                        Text(text).ipaFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button("Open") { Task { await installer.open(app.identifier, preferIndependent: true) } }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                                if let update = updates[IPAInstalledAppUpdate.id(app.identifier, independent: true)] {
                                    updateButton(update)
                                }
                            }.contextMenu { Button("Remove from List", role: .destructive) { forgetting = app } }
                        }
                    }.padding(.horizontal, 20).padding(.bottom)
                }
                VStack {
                    if LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                        if sharedModel.isHiddenAppUnlocked {
                            LazyVStack {
                                HStack {
                                    Text("lc.appList.hiddenApps".loc)
                                        .font(.system(.title2).bold())
                                    Spacer()
                                }
                                
                                ForEach(filteredHiddenApps, id: \.self) { app in
                                    LCAppBanner(appModel: app, delegate: self, subtitle: subtitleText(for: app))
                                }
                                .transition(.opacity)
                                
                            }
                            .padding()
                            .transition(.opacity)
                            .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                            
                            if sharedModel.hiddenApps.count == 0 {
                                Text("lc.appList.hideAppTip".loc)
                                    .foregroundStyle(.gray)
                            }
                        }
                    } else if sharedModel.hiddenApps.count > 0 {
                        LazyVStack {
                            HStack {
                                Text("lc.appList.hiddenApps".loc)
                                    .font(.system(.title2).bold())
                                Spacer()
                            }
                            ForEach(filteredHiddenApps, id: \.self) { app in
                                if sharedModel.isHiddenAppUnlocked {
                                    LCAppBanner(appModel: app, delegate: self, subtitle: subtitleText(for: app))
                                } else {
                                    LCAppSkeletonBanner()
                                }
                            }
                            .animation(.easeInOut, value: sharedModel.isHiddenAppUnlocked)
                            .onTapGesture {
                                Task { await authenticateUser() }
                            }
                        }
                        .padding()
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                    }
                }.animation(searchContext.isTyping ? nil : .easeInOut, value: LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding"))

                if sharedModel.multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc).foregroundStyle(.gray).padding()
                }

            }
            .overlay {
                if sortedApps.isEmpty && sortedHiddenApps.isEmpty && installer.independentApps.isEmpty && installer.jobs.isEmpty && guestSession.interruptedRecord == nil {
                    IPACollectionEmptyState(symbol: IPAStyle.appsSymbol, message: "Your downloaded apps appear here.") {}
                        .onTapGesture(count: 3) { Task { await authenticateUser() } }
                }
            }
            .coordinateSpace(name: "scroll")
            .onAppear {
                if !didAppear {
                    onAppear()
                }
            }
            
            .ipaCollectionToolbar {
                if sharedModel.multiLCStatus != 2 {
                    IPAAppActions(
                        add: { choosingIPA = true }, addDisabled: installprogressVisible,
                        refresh: { showingUpdates = true },
                        search: { collectionSearch = true },
                        sort: { sortingApps = true }
                    )
                }
            }
            .modifier(IPACollectionSearch(query: $searchContext.query, presented: $collectionSearch))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .background(IPAStyle.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo.ipaDisplayMessage)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .sheet(isPresented: $sortingApps) {
            IPACollectionSortSheet(selection: $sharedAppSortManager.appSortType,
                                   options: AppSortType.allCases, title: \.displayName)
        }
        .sheet(isPresented: $showingUpdates) {
            IPAInstalledAppUpdates(apps: sortedApps.filter { !$0.uiIsHidden && !$0.uiIsLocked },
                                   independentApps: installer.independentApps)
                .environmentObject(catalog).environmentObject(discovery).environmentObject(catalogIndex)
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .confirmationDialog("Remove from Apps?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Remove from List", role: .destructive) { if let app = forgetting { installer.forgetIndependent(app.identifier) }; forgetting = nil }
        } message: { Text("This removes the entry from IPAStore. To delete the app itself, use the iPhone Home Screen.") }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                Task { await installFromUrl(urlStr: installUrl.absoluteString) }
            }
        }

    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    func startInstallApp(_ fileUrl: URL) async {
        do { try await installIpaFile(fileUrl) }
        catch is CancellationError { }
        catch { /* The shared installation sheet provides recovery. */ }
    }

    func installIpaFile(_ url: URL) async throws {
        try await IPAInstallCoordinator.shared.importFile(url)
        for app in sharedModel.apps + sharedModel.hiddenApps { app.delegate = self }
        installprogressVisible = false
    }

    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) async {
        // ignore any install request if we are installing another app
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard var installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        self.installprogressVisible = true
        defer {
            self.installprogressVisible = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    errorShow = true
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }
            
            do { try await installIpaFile(installUrl) }
            catch is CancellationError { }
            catch { /* The shared installation sheet provides recovery. */ }

            return
        }
        
        do { try await IPAInstallCoordinator.shared.importURL(installUrl) }
        catch is CancellationError { }
        catch { /* Recovery is presented by the shared installer. */ }
    }
    

    func showProduct(app: LCAppModel) {
        Task { @MainActor in
            do {
                if app.uiIsLocked { guard try await LCUtils.authenticateUser() else { return } }
                openNavigationView(view: AnyView(IPAInstalledProductView(app: app)))
            } catch { errorInfo = error.localizedDescription.ipaDisplayMessage; errorShow = true }
        }
    }

    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}


private struct IPAInstalledAppUpdate: Identifiable {
    var id: String { Self.id(variant.app.bundleIdentifier, independent: independent) }
    let variant: IPAAppVariant
    let installed: String
    let latest: String
    let independent: Bool

    static func id(_ identifier: String, independent: Bool) -> String {
        (independent ? "device|" : "container|") + identifier.lowercased()
    }

    @MainActor static func matches(apps: [LCAppModel], independentApps: [IPAIndependentApp],
                                   index: IPAAllAppsIndex, history: [IPAActivityRecord]) -> [Self] {
        let originsByID = Dictionary(grouping: history, by: { $0.identifier.lowercased() })
        let containerCopies = Dictionary(grouping: apps.compactMap { app in
            app.appInfo.bundleIdentifier().map { ($0, app.version) }
        }, by: { $0.0.lowercased() })
        let containerRecords = containerCopies.values.compactMap { copies -> (String, String, Bool)? in
            guard copies.count == 1, let (identifier, version) = copies.first else { return nil }
            return (identifier, version, false)
        }
        let deviceRecords = independentApps.compactMap { app -> (String, String, Bool)? in
            let recent = originsByID[app.identifier.lowercased()]?.first { abs($0.date.timeIntervalSince(app.installedAt)) < 60 }
            return (app.version ?? recent?.version).map { (app.identifier, $0, true) }
        }
        return (containerRecords + deviceRecords).compactMap { identifier, version, independent in
            let key = identifier.lowercased()
            let matching = (originsByID[key] ?? []).filter { record in
                record.version.map { IPACompatibility.compare($0, version) == .orderedSame } == true
            }
            let origins = Set(matching.compactMap(\.libraryURL).map(IPAStoreDirectory.canonical))
            guard matching.allSatisfy({ $0.libraryURL != nil }), origins.count == 1,
                  let origin = origins.first,
                  let entry = index.entry(identifier: identifier),
                  let candidate = entry.variants.first(where: {
                      $0.store.id == origin && $0.app.bundleIdentifier.lowercased() == key
                  }),
                  let release = candidate.app.latestVersion,
                  IPACompatibility.compare(release.version, version) == .orderedDescending,
                  IPACompatibility.issue(minimum: release.minOSVersion, maximum: release.maxOSVersion, current: UIDevice.current.systemVersion) == nil,
                  candidate.store.suggestion?.marketplaceOnly != true else { return nil }
            return Self(variant: candidate, installed: version, latest: release.version, independent: independent)
        }
    }
}

private struct IPAInstalledAppUpdates: View {
    let apps: [LCAppModel]
    let independentApps: [IPAIndependentApp]
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @EnvironmentObject private var discovery: IPADiscovery
    @EnvironmentObject private var index: IPAAllAppsIndex
    @Environment(\.dismiss) private var dismiss
    @State private var checking = true
    @State private var updates: [IPAInstalledAppUpdate] = []
    @State private var failedChecks = 0
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if !checking && failedChecks > 0 {
                    Label(failedChecks == 1 ? "1 store couldn’t be refreshed" : "\(failedChecks) stores couldn’t be refreshed",
                          systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                if checking {
                    ProgressView("Checking for updates…")
                } else if updates.isEmpty {
                    ContentUnavailableView("No Updates Found", systemImage: "checkmark.circle",
                                           description: Text("Available versions are checked against each app’s original store."))
                } else {
                    Section {
                        ForEach(updates) { update in
                            Button {
                                if !selected.insert(update.id).inserted { selected.remove(update.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    IPAArtwork(url: update.variant.app.iconURL, size: 42)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(update.variant.app.name).ipaFont(.headline)
                                        Text("\(update.installed) → \(update.latest) · \(update.variant.store.name)")
                                            .ipaFont(.caption).foregroundStyle(.secondary)
                                        Text(update.independent ? "On Your iPhone" : "Inside iPAStore")
                                            .ipaFont(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected.contains(update.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                }.foregroundStyle(.primary).padding(.vertical, 4)
                            }.accessibilityAddTraits(selected.contains(update.id) ? .isSelected : [])
                        }
                    }
                    Section {
                        Button("Download Selected", systemImage: "arrow.down.circle") { download(updates.filter { selected.contains($0.id) }) }
                            .disabled(selected.isEmpty)
                        Button("Download All Updates", systemImage: "arrow.down.to.line") { download(updates) }
                    }
                }
            }
            .navigationTitle("App Updates").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.foregroundStyle(.primary) } }
        }.task { await check() }
    }

    private func check() async {
        async let feeds: Void = catalog.refreshAllSources()
        async let suggestions: Void = discovery.load(force: true)
        _ = await (feeds, suggestions)
        index.rebuild(subscribed: catalog.sources, discovered: discovery.sources)
        await index.waitForRebuild()
        guard !Task.isCancelled else { return }
        failedChecks = catalog.sources.filter { $0.error != nil }.count
        updates = IPAInstalledAppUpdate.matches(apps: apps, independentApps: independentApps, index: index,
                                                history: IPAActivityHistory.shared.downloads)
            .sorted { $0.variant.app.name.localizedStandardCompare($1.variant.app.name) == .orderedAscending }
        checking = false
    }

    private func download(_ updates: [IPAInstalledAppUpdate]) {
        for update in updates { IPAInstallCoordinator.shared.start(update.variant, independent: update.independent) }
        dismiss()
    }
}
