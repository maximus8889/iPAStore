// IPAStore presentation. Engine and dependency credits remain in About.
import SwiftUI
import SafariServices
#if canImport(SideStoreSupport)
import SideStoreSupport
#endif

enum IPAStyle {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.systemBackground.resolvedColor(with: traits) : UIColor(red: 0.98, green: 0.977, blue: 0.968, alpha: 1)
    })
    static let productCanvas = Color(uiColor: .systemGray6)
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white })
    static let storeSymbol = "rectangle.stack"
    static let appsSymbol = "square.grid.2x2"
    static let inset: CGFloat = 20
    static let tabCollectionButtonSize: CGFloat = 46
}

extension String {
    var ipaDisplayMessage: String {
        replacingOccurrences(of: "Signing & Refresh", with: "Settings → Manage")
            .replacingOccurrences(of: "Refresh All Apps", with: "Refresh")
            .replacingOccurrences(of: "LiveContainer+SideStore", with: "iPAStore")
            .replacingOccurrences(of: "SideStore+LiveContainer", with: "iPAStore")
            .replacingOccurrences(of: "LiveContainer", with: "iPAStore")
            .replacingOccurrences(of: "SideStore", with: "iPAStore")
    }
}

struct IPABrandGlyph: View {
    var size: CGFloat = 60
    var body: some View {
        Image("BrandGlyph").resizable().renderingMode(.template).scaledToFit()
            .frame(width: size, height: size).foregroundStyle(.primary).accessibilityHidden(true)
    }
}

struct IPARootTabs: View {
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @StateObject private var index = IPAAllAppsIndex()
    @EnvironmentObject private var model: SharedModel
    @StateObject private var discovery = IPADiscovery()
    @AppStorage("IPADidSeeWelcome") private var didSeeWelcome = false
    @State private var showWelcome = false
    @State private var checkedWelcome = false
    #if !IPASTORE_PREVIEW
    @ObservedObject private var guestSession = IPAAppSession.shared
    #endif
    @State private var refreshedAtLaunch = false
    init() {
        IPAAppearance.registerFonts()
        UINavigationBar.appearance().tintColor = .label
    }
    @AppStorage("IPAAccentHex") private var accentHex = "systemBlue"
    @AppStorage("IPAAppearance") private var appearance = "system"
    var body: some View {
        IPATabPager(selection: $model.selectedTab,
                    pages: [page(IPATodayView()), page(IPAStoresView()), page(library), page(IPASettingsView()), page(IPASearchView())],
                    accent: IPAAppearance.accent(accentHex), appearance: appearance)
            .ignoresSafeArea()
            .onAppear {
                guard !checkedWelcome else { return }
                checkedWelcome = true
                showWelcome = !didSeeWelcome
            }
            .fullScreenCover(isPresented: $showWelcome) {
                IPAWelcomeView { didSeeWelcome = true; showWelcome = false }
                    .environmentObject(model).modifier(IPATheme())
            }
            .environmentObject(discovery).environmentObject(index)
            .onReceive(model.$apps) { IPAInstallCoordinator.shared.updateInstalledIdentifiers($0.compactMap { $0.appInfo.bundleIdentifier() }) }
            .onReceive(catalog.$sources.removeDuplicates(by: { a, b in
                a.count == b.count && zip(a, b).allSatisfy { x, y in x.url == y.url && x.source?.id == y.source?.id && x.lastCheckedAt == y.lastCheckedAt }
            })) { snapshot in
                Task { @MainActor in
                    discovery.adoptCatalog(snapshot)
                    index.rebuild(subscribed: catalog.sources, discovered: discovery.sources)
                }
            }
            .onReceive(discovery.$sources) { snapshot in
                let checked = discovery.checkedSnapshot(snapshot)
                Task { @MainActor in
                    catalog.adoptDiscovery(checked)
                    index.rebuild(subscribed: catalog.sources, discovered: discovery.sources)
                }
            }
            .task {
                guard !refreshedAtLaunch else { return }
                refreshedAtLaunch = true
                await discovery.load(force: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                Task { await IPAImagePipeline.shared.trimMemory() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                IPALibraryIndex.shared.trimMemory()
                Task { await IPAImagePipeline.shared.trimMemory() }
            }
            .modifier(IPAInstallationOverlay()).environmentObject(index).modifier(IPATheme())
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--verify-navigation") || arguments.contains("--verify-motion") || arguments.contains("--verify-performance") || arguments.contains("--verify-search-layout") {
                    for _ in 0..<300 where UIApplication.shared.applicationState != .active {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--verify-navigation") { await IPANavigationChecks.run() }
                if ProcessInfo.processInfo.arguments.contains("--verify-motion") { await IPATabMotionChecks.run() }
                if arguments.contains("--verify-performance") { await IPAArtworkPerformanceChecks.run() }
                if arguments.contains("--verify-search-layout") { await IPASearchLayoutChecks.run() }
            }
            #if !IPASTORE_PREVIEW
            .modifier(IPAAppSessionPresentation())
            #endif
    }
    private func page<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(model).environmentObject(catalog).environmentObject(discovery).environmentObject(index)
            .modifier(IPATheme()))
    }
    @ViewBuilder private var library: some View {
        #if IPASTORE_PREVIEW
        PreviewAppsView()
        #else
        LCAppListView()
        #endif
    }
}

struct IPAArtwork: View {
    let url: URL?
    var size: CGFloat = 62
    var identifier: String? = nil
    @State private var alternate: URL?
    @State private var requested = false
    var body: some View {
        IPARemoteImage(url: url, pixels: Int(size * 3), fallbackURLs: [alternate].compactMap { $0 }, onFailure: {
            guard !requested, identifier != nil else { return }; requested = true
        })
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
            .task(id: requested ? identifier : nil) {
                guard requested, let identifier else { return }
                let metadata = await IPAProductMetadataResolver.shared.resolve(identifier)
                if !Task.isCancelled { alternate = metadata?.icon }
            }
    }
}

struct IPATabHeading: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title).ipaFont(.largeTitle, weight: .bold)
            .accessibilityAddTraits(.isHeader)
            .frame(minHeight: 44, alignment: .topLeading)
    }
}

struct IPACollectionActions<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            let size = IPAStyle.tabCollectionButtonSize
            let icon = IPACollectionControlIcon.plus.frame(width: size, height: size).contentShape(Circle())
            if #available(iOS 26.0, *) {
                icon.glassEffect(.regular, in: .circle)
            } else {
                icon.background(IPAStyle.card, in: Circle())
            }
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(title))
    }
}

extension View {
    func ipaCollectionToolbar<Actions: View>(@ViewBuilder actions: () -> Actions) -> some View {
        overlay(alignment: .top) {
            actions()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
    }
}

struct IPAAppActions: View {
    let add: () -> Void
    var addDisabled = false
    let refresh: (() -> Void)?
    let search: () -> Void
    let sort: (() -> Void)?

    var body: some View {
        IPACollectionActions(title: "App actions") {
            Button("Add", systemImage: "plus", action: add).disabled(addDisabled)
            Button("Refresh", systemImage: "arrow.clockwise") { refresh?() }.disabled(refresh == nil)
            Button("Search", systemImage: "magnifyingglass", action: search)
            Button("Sort", systemImage: "line.3.horizontal.decrease") { sort?() }.disabled(sort == nil)
        }
    }
}

struct IPACollectionEmptyState<Action: View>: View {
    let symbol: String
    let message: LocalizedStringKey
    @ViewBuilder let action: () -> Action

    var body: some View {
        GeometryReader { geometry in
            let top = geometry.frame(in: .global).minY
            let windowTop = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .compactMap(\.keyWindow).first?.safeAreaInsets.top ?? top
            VStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: 48, weight: .light))
                    .frame(width: 62, height: 62)
                    .accessibilityHidden(true)
                Text(message).ipaFont(.subheadline)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .overlay(alignment: .bottom) {
                action().alignmentGuide(.bottom) { $0[.top] - 14 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Align pushed collections with tab roots below the status bar.
            .offset(y: -max(0, top - windowTop) / 2)
        }
    }
}

struct IPAEmptyState: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text(title).ipaFont(.title2, weight: .bold)
            Text(subtitle).ipaFont(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity)
    }
}

struct IPAGetButton: View {
    let variant: IPAAppVariant
    var showsStatus = false
    var prominent = false
    var alwaysFilled = false
    @ObservedObject private var activity = IPAActivityHistory.shared
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    @AppStorage("IPAInstallMode") private var mode = "container"
    @AppStorage("IPAAccentHex") private var accentHex = "systemBlue"
    @AppStorage("IPAFilledButtons") private var filledButtons = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var installedIdentifier: String { installer.installedIdentifier(for: variant) }
    private var installed: Bool { installer.isInstalled(installedIdentifier) }
    private var opening: Bool { installer.openingIdentifier == installedIdentifier }
    var body: some View {
        ZStack {
            if let job = installer.job(for: variant, independent: mode == "independent") {
                IPAJobProgressButton(job: job, showsStatus: showsStatus)
                    .frame(maxWidth: showsStatus ? 140 : nil)
                    .transition(IPAMotion.reveal(reduced: reduceMotion))
            } else {
                Button {
                    if installed {
                        #if !IPASTORE_PREVIEW
                        Task { await installer.open(installedIdentifier, preferIndependent: mode == "independent") }
                        #endif
                    } else { installer.start(variant, independent: mode == "independent") }
                } label: {
                    if !installed && activity.wasDownloaded(variant.app.bundleIdentifier) { Image(systemName: "icloud.and.arrow.down").ipaFont(.title3, weight: .semibold) }
                    else { ZStack {
                        Text(installed ? "Open" : "Get").opacity(opening ? 0 : 1)
                        if opening { ProgressView().tint((alwaysFilled || (prominent && filledButtons)) ? IPAAppearance.buttonForeground(accentHex) : IPAAppearance.accent(accentHex)).transition(.opacity) }
                    } }
                }.buttonStyle(IPAPillStyle(prominent: prominent, alwaysFilled: alwaysFilled))
                    .disabled(installed && installer.openingIdentifier != nil)
                    .contentTransition(.opacity)
                    .transition(IPAMotion.reveal(reduced: reduceMotion))
                    .accessibilityLabel("\(installed ? "Open" : "Get") \(variant.app.name)")
            }
        }.frame(minWidth: 66)
            .animation(IPAMotion.state(reduced: reduceMotion), value: installed)
            .animation(IPAMotion.state(reduced: reduceMotion), value: installer.job(for: variant, independent: mode == "independent")?.id)
            .animation(IPAMotion.state(reduced: reduceMotion), value: opening)
    }
}

struct IPAAppRow: View {
    let entry: IPAAppEntry
    var onVisit: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 12) {
            NavigationLink { IPAProductView(entry: entry) } label: {
                HStack(spacing: 12) {
                    IPAArtwork(url: entry.app.iconURL, size: 60, identifier: entry.app.bundleIdentifier)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.app.name).ipaFont(.headline, weight: .semibold).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                        if let subtitle = IPACatalogPresentation.displayValue(entry.app.subtitle)
                            ?? IPACatalogPresentation.displayValue(entry.app.description)
                            ?? IPACatalogPresentation.displayValue(entry.app.developerName) {
                            Text(subtitle).ipaFont(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(IPAControlPressStyle(scale: 0.985)).simultaneousGesture(TapGesture().onEnded { onVisit?() })
            IPAGetButton(variant: entry.primary)
        }.padding(.vertical, 9)
    }
}

struct IPACategoryShelves: View {
    let categories: [IPAAppCategory]
    let title: String?
    let library: IPAStoreReference?
    init(entries: [IPAAppEntry], title: String? = nil) {
        self.init(categories: IPACatalogPresentation.categories(entries), title: title)
    }
    init(categories: [IPAAppCategory], title: String? = nil, library: IPAStoreReference? = nil) {
        self.categories = categories
        self.title = title
        self.library = library
    }
    var body: some View {
        // Only a handful of bounded shelves: keep their heights resolved rather
        // than adjusting nested lazy-stack estimates during vertical scrolling.
        VStack(alignment: .leading, spacing: 28) {
            if let title { Text(title).ipaFont(.title2, weight: .bold) }
            ForEach(categories) { category in
                IPACategoryShelf(category: category, library: category.name == "All Apps" ? library : nil)
            }
        }
    }
}

struct IPACategoryShelf: View {
    let category: IPAAppCategory
    var library: IPAStoreReference? = nil
    @ScaledMetric(relativeTo: .body) private var rowHeight = 82.0
    private var pages: [[IPAAppEntry]] {
        IPACatalogPresentation.shelfPages(category.apps)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink {
                if let library { IPAStoreAllAppsView(reference: library) }
                else { IPACategoryView(category: category) }
            } label: {
                HStack(spacing: 6) { Text(category.name).ipaFont(.title3, weight: .bold); Image(systemName: "chevron.right").ipaFont(.subheadline, weight: .semibold).foregroundStyle(.tertiary) }.foregroundStyle(.primary)
            }.buttonStyle(.plain).accessibilityLabel(category.name == "All Apps" ? "All Apps" : "All \(category.name)")
            if category.apps.isEmpty {
                Text("No apps in this category yet.").ipaFont(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
            } else {
                IPAAppShelfPages(pages: pages, title: category.name, rowHeight: rowHeight) { entry in
                    IPAAppRow(entry: entry)
                }
            }
        }
    }
}

struct IPAAppShelfPages<Item: Identifiable, Row: View>: View {
    let pages: [[Item]]
    let title: String
    let rowHeight: CGFloat
    @ViewBuilder let row: (Item) -> Row

    private let gap: CGFloat = 16
    private let nextPagePreview: CGFloat = 6
    private var height: CGFloat { rowHeight * CGFloat(pages.first?.count ?? 0) + 4 }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: gap) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        let width = index == pages.count - 1 ? geometry.size.width
                            : max(1, geometry.size.width - gap - nextPagePreview)
                        VStack(spacing: 0) {
                            ForEach(page) { item in
                                row(item).frame(minHeight: rowHeight)
                                if item.id != page.last?.id { Divider().padding(.leading, 72) }
                            }
                        }
                        .frame(width: width, height: height, alignment: .topLeading)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(title), page \(index + 1)")
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(height: height)
    }
}

struct IPACategoryView: View {
    let category: IPAAppCategory
    @State private var searching = false
    @State private var query = ""
    @State private var order = "publisher"
    @State private var sortCenter: CGFloat?
    @State private var results: [IPAAppEntry]
    @State private var prepared: [IPASearchDocument]?
    init(category: IPAAppCategory) { self.category = category; _results = State(initialValue: category.apps) }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if results.isEmpty { IPAEmptyState(title: query.isEmpty ? "No Apps Yet" : "No Results", subtitle: query.isEmpty ? "Apps in this category will appear here as the library updates." : "Try another app or developer name.", symbol: query.isEmpty ? "square.stack.3d.up" : "magnifyingglass") }
                IPAPagedAppRows(entries: results).id(query + "|" + order)
            }.padding(.horizontal, 20).padding(.bottom, 24).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.task(id: query + "|" + order) {
            let text = query, sorting = order, snapshot = category.apps, existing = prepared
            do {
                if !text.isEmpty { try await Task.sleep(nanoseconds: 150_000_000) }
                let task = Task.detached(priority: .userInitiated) { () -> ([IPAAppEntry], [IPASearchDocument]) in
                    let documents = existing ?? snapshot.map(IPASearchDocument.init)
                    var rows = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? snapshot : IPASearchDocument.matches(text, documents: documents).map { snapshot[$0] }
                    if sorting == "name" { rows.sort { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending } }
                    if sorting == "developer" { rows.sort { ($0.app.developerName ?? "").localizedStandardCompare($1.app.developerName ?? "") == .orderedAscending } }
                    return (rows, documents)
                }
                let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation(); results = value.0; prepared = value.1
            } catch { }
        }.modifier(IPACollectionSearch(query: $query, presented: $searching, closeButtonCenter: sortCenter))
            .background(IPAStyle.canvas).navigationTitle(category.name).navigationBarTitleDisplayMode(.inline).ipaNativePage()
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Search", systemImage: "magnifyingglass") { searching = true }
                    Picker("Sort", selection: $order) { Text("Library Order").tag("publisher"); Text("Name").tag("name"); Text("Developer").tag("developer") }
                        .pickerStyle(.inline).labelsHidden()
                } label: {
                    IPACollectionControlIcon(symbol: "line.3.horizontal.decrease")
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { sortCenter = $0 }
                }
                .accessibilityLabel("Sort and search apps")
            } }
    }
}

struct IPATodayView: View {
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @EnvironmentObject private var discovery: IPADiscovery
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        VStack(alignment: .leading, spacing: 4) {
                            IPATabHeading("Today")
                            Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day()).ipaFont(.subheadline, weight: .medium).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                        if let suggested = discovery.featured {
                            let reference = IPAStoreReference(suggested)
                            let source = discovery.sources[suggested.id]
                            IPAFeaturedLibrary(reference: reference, source: source).id(reference.id)
                            if source == nil, !discovery.loading {
                                Button("Reload This Library") { Task { await discovery.load(force: true) } }.frame(maxWidth: .infinity)
                            }
                        } else if discovery.loading {
                            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(IPAStyle.card)
                                .frame(height: 430).overlay { ProgressView() }.accessibilityLabel("Loading today’s library")
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 30).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }.background(IPAStyle.canvas)
                    .task(id: Calendar.current.startOfDay(for: context.date)) { discovery.updateFeatured(on: context.date) }
            }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .refreshable {
                    async let subscriptions: Void = catalog.refreshAllSources()
                    async let suggestions: Void = discovery.load(force: true)
                    _ = await (subscriptions, suggestions)
                }
        }
    }
}

struct IPAFeaturedLibrary: View {
    let reference: IPAStoreReference
    let source: AltStoreSource?
    @ObservedObject private var libraryIndex = IPALibraryIndex.shared
    @State private var palette: [Color] = []
    @State private var header: UIImage?
    private var asset: String? { reference.suggestion?.bundledIconName }
    private var url: URL? { source?.iconURL ?? reference.suggestion?.iconURL ?? source?.apps.first?.iconURL }
    private var entries: [IPAAppEntry] { libraryIndex.entries(reference: reference, source: source) }
    private var initialPalette: [Color] { IPAIconPalette.colors(asset.flatMap(UIImage.init(named:))) }
    var body: some View {
        NavigationLink { IPAStorePage(reference: reference) } label: {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
              ZStack(alignment: .bottomLeading) {
                Rectangle().fill(LinearGradient(colors: palette.isEmpty ? initialPalette : palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                if let header {
                    Image(uiImage: header).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    IPAStoreArtwork(source: source, reference: reference, size: 138).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIBRARY OF THE DAY").ipaFont(.caption, weight: .semibold).tracking(0.8).foregroundStyle(.white.opacity(0.8))
                    Text(reference.name).ipaFont(.title, weight: .bold).foregroundStyle(.white).lineLimit(2).truncationMode(.tail)
                }.padding(22)
              }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.frame(height: 270).clipped().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                Text(reference.summary).ipaFont(.subheadline).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    IPAStoreArtwork(source: source, reference: reference, size: 46)
                    Text(reference.name).ipaFont(.headline, weight: .semibold).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }.padding(20)
        }.background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }.buttonStyle(.plain).contentShape(RoundedRectangle(cornerRadius: 26))
            .accessibilityElement(children: .combine).accessibilityHint("Open this library")
            .task(id: url) {
                palette = []
                if let url, let image = await IPAImagePipeline.shared.image(url, pixels: 96), !Task.isCancelled { palette = IPAIconPalette.colors(image) }
            }
            .task(id: source?.headerURL) {
                header = nil
                if let url = source?.headerURL, let image = await IPAImagePipeline.shared.image(url, pixels: 1100), !Task.isCancelled { header = image }
            }
            .task(id: source?.id) {
                guard let source else { return }
                await libraryIndex.prepare(reference: reference, source: source)
                guard !Task.isCancelled else { return }
                var seen = Set<URL>()
                let icons = libraryIndex.browsingCategories(reference: reference, source: source)
                    .flatMap { $0.apps.prefix(3).compactMap { $0.app.iconURL } }
                    .filter { seen.insert($0).inserted }.prefix(9)
                await withTaskGroup(of: Void.self) { group in
                    for icon in icons { group.addTask { _ = await IPAImagePipeline.shared.image(icon, pixels: 180) } }
                }
            }
    }
}

struct IPAStoresView: View {
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @EnvironmentObject private var discovery: IPADiscovery
    @EnvironmentObject private var model: SharedModel
    @State private var path = NavigationPath()
    @State private var suggestions = false
    @State private var query = ""
    @State private var searching = false
    @State private var sorting = false
    @AppStorage("IPASourceSort") private var sourceSort = IPAStoreSort.defaultOrder.rawValue
    @AppStorage("IPASourceOrder") private var sourceOrder = "[]"

    private var selectedSort: IPAStoreSort {
        if sourceSort == "name" { return .alphabetical }
        if sourceSort == "manual" { return sourceOrder == "[]" ? .defaultOrder : .custom }
        return IPAStoreSort(rawValue: sourceSort) ?? .defaultOrder
    }

    private var sortedSources: [AltStoreSourcesViewModel.SourceItem] {
        selectedSort.ordered(catalog.sources, savedOrder: sourceOrder)
    }

    private var visibleSources: [AltStoreSourcesViewModel.SourceItem] {
        sortedSources.filter { query.isEmpty || IPAStoreDirectory.title(for: $0).localizedCaseInsensitiveContains(query) }
    }
    @State private var refreshDetails = false
    private var failedSources: [AltStoreSourcesViewModel.SourceItem] { catalog.sources.filter { $0.error != nil } }
    @State private var adding = false
    @State private var failure: String?
    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        IPATabHeading("Stores")
                            .padding(.trailing, 54).frame(maxWidth: .infinity, alignment: .leading)
                            .id("stores-heading")
                        IPACollectionSearchField(query: $query, presented: $searching, prompt: "Search Libraries", belowTabHeading: true)
                        if !failedSources.isEmpty {
                            Button { refreshDetails = true } label: {
                                Label(failedSources.count == 1 ? "1 store needs attention" : "\(failedSources.count) stores need attention",
                                      systemImage: "exclamationmark.circle").ipaFont(.subheadline)
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        } else if !catalog.sources.isEmpty {
                            Text(catalog.sources.count == 1 ? "1 store" : "\(catalog.sources.count) stores")
                                .ipaFont(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(visibleSources) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            IPALibraryCard(reference: IPAStoreReference(item), source: item.source, subtitle: item.source.flatMap { $0.apps.isEmpty ? nil : "\($0.apps.count) \($0.apps.count == 1 ? "app" : "apps")" } ?? (item.error == nil ? "App library" : "Unavailable · see update details"))

                        }.contextMenu {
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await catalog.refreshSource(item) } }
                            if item.error != nil { Button("Update Details", systemImage: "exclamationmark.circle") { refreshDetails = true } }
                            Button("Remove Library", systemImage: "trash", role: .destructive) { catalog.removeSource(item) }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .refreshable { await refreshLibraries() }
            .onChange(of: searching) { _, shown in if shown { proxy.scrollTo("stores-heading", anchor: .top) } }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if catalog.sources.isEmpty, !searching {
                    IPACollectionEmptyState(symbol: IPAStyle.storeSymbol, message: "Your added stores appear here.") {
                        Button("Add a Library") { suggestions = true }
                            .buttonStyle(IPAPillStyle(prominent: true, compact: true))
                    }
                }
            }
            .background(IPAStyle.canvas).navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .ipaCollectionToolbar {
                    IPACollectionActions(title: "Store actions") {
                        Button("Add", systemImage: "plus") { adding = true }
                        Button("Suggestions", systemImage: "sparkles") { suggestions = true }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshLibraries() } }
                        Button("Search", systemImage: "magnifyingglass") { searching = true }
                        Button("Sort", systemImage: "line.3.horizontal.decrease") { sorting = true }
                    }
                }
                .sheet(isPresented: $sorting) {
                    IPACollectionSortSheet(selection: Binding(get: { selectedSort }, set: { sourceSort = $0.rawValue }),
                                           options: IPAStoreSort.allCases, title: \.title) {
                        let order = sourceOrder == "[]" ? selectedSort : .custom
                        IPAArrangeLibraries(items: order.ordered(catalog.sources, savedOrder: sourceOrder)) { ids in
                            if let data = try? JSONEncoder().encode(ids) {
                                sourceOrder = String(decoding: data, as: UTF8.self)
                                sourceSort = IPAStoreSort.custom.rawValue
                            }
                        }
                    }
                }
                .navigationDestination(isPresented: $suggestions) { IPASuggestionsView() }
                .navigationDestination(for: IPAStoreReference.self) { IPAStorePage(reference: $0) }
            }
        }
        .sheet(isPresented: $refreshDetails) { IPALibraryRefreshDetails() }
        .sheet(isPresented: $adding) { IPAAddStoreSheet() }
        .alert("Unable to Add Library", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
        .onChange(of: model.selectedTab) { oldTab, newTab in
            if oldTab == .sources && newTab != .sources { refreshDetails = false }
        }
        .onChange(of: model.deepLink) { link in
            guard model.selectedTab == .sources, let link, link.host == "source", let components = URLComponents(url: link, resolvingAgainstBaseURL: false), let address = components.queryItems?.first(where: { $0.name == "url" })?.value else { return }
            model.deepLink = nil
            Task { failure = await catalog.addSource(from: address) }
        }
    }

    private func refreshLibraries() async {
        async let stored: Void = catalog.refreshAllSources()
        async let suggested: Void = discovery.load(force: true)
        _ = await (stored, suggested)
    }

}

private struct IPALibraryRefreshDetails: View {
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @Environment(\.dismiss) private var dismiss
    private var failed: [AltStoreSourcesViewModel.SourceItem] { catalog.sources.filter { $0.error != nil } }
    var body: some View {
        NavigationStack {
            List {
                if failed.isEmpty { Label(catalog.isRefreshingAll ? "Checking libraries…" : "No libraries need attention.", systemImage: catalog.isRefreshingAll ? "arrow.clockwise" : "checkmark.circle").foregroundStyle(.secondary) }
                ForEach(failed) { item in
                    Section(IPAStoreDirectory.title(for: item)) {
                        Text(item.error ?? "").ipaFont(.subheadline)
                        if let checked = item.lastCheckedAt { LabeledContent("Last Successful Check") { Text(checked, style: .relative).ipaFont(.caption) } }
                        if let publisher = IPAStoreDirectory.suggestion(for: item.url)?.publisher ?? item.source?.website {
                            IPAWebLink(destination: publisher) { Label("Visit Publisher", systemImage: "arrow.up.right") }
                        }
                        Button("Try Again") { Task { await catalog.refreshSource(item) } }.disabled(item.isLoading)
                    }
                }
                Text("Available libraries continue to update. Saved catalogs stay available when a publisher is offline or removes an address.").ipaFont(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("Library Updates").navigationBarTitleDisplayMode(.inline).ipaNativePage()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// Keep the native search field inside the Search page. A navigation-owned
// UISearchController can retain its native back row over a custom product page.
// The adjacent button dismisses the keyboard while keeping the current query.
struct IPACatalogSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    var prompt = "Apps, developers and libraries"
    var autofocus = false
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, editing: $editing) }
    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.placeholder = prompt
        bar.returnKeyType = .search
        bar.searchTextField.autocapitalizationType = .none
        bar.searchTextField.autocorrectionType = .no
        bar.searchTextField.clearButtonMode = .never
        bar.searchTextField.accessibilityLabel = prompt
        bar.delegate = context.coordinator
        return bar
    }
    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.text = $text
        if bar.text != text { bar.text = text }
        if autofocus && !context.coordinator.requestedFocus {
            context.coordinator.requestedFocus = true
            DispatchQueue.main.async { [weak bar] in bar?.searchTextField.becomeFirstResponder() }
        }
    }
    static func dismantleUIView(_ bar: UISearchBar, coordinator: Coordinator) {
        coordinator.removeDismissTap()
    }

    final class Coordinator: NSObject, UISearchBarDelegate, UIGestureRecognizerDelegate {
        var text: Binding<String>
        var editing: Binding<Bool>
        var requestedFocus = false
        private weak var searchBar: UISearchBar?
        private lazy var dismissTap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        init(text: Binding<String>, editing: Binding<Bool>) {
            self.text = text
            self.editing = editing
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            editing.wrappedValue = true
            self.searchBar = searchBar
            searchBar.window?.addGestureRecognizer(dismissTap)
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            editing.wrappedValue = false
            removeDismissTap()
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { text.wrappedValue = searchText }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.searchTextField.resignFirstResponder() }

        func removeDismissTap() {
            dismissTap.view?.removeGestureRecognizer(dismissTap)
            searchBar = nil
        }

        @objc private func dismissKeyboard() {
            searchBar?.searchTextField.resignFirstResponder()
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let field = searchBar?.searchTextField, let window = field.window,
                  !field.convert(field.bounds, to: window).contains(touch.location(in: window)) else { return false }
            var view = touch.view
            while let current = view {
                if current is UIControl || current is UISearchBar { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

struct IPASearchView: View {
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @EnvironmentObject private var index: IPAAllAppsIndex
    @EnvironmentObject private var discovery: IPADiscovery
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var editingSearch = false
    @State private var results: [IPAAppEntry] = []
    @State private var searching = false
    @ObservedObject private var history = IPAActivityHistory.shared
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    IPATabHeading("Search")
                        .frame(maxWidth: 720, alignment: .leading).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
                        .frame(maxWidth: 760).frame(maxWidth: .infinity).id("ipa-search-top")
                    Section {
                    LazyVStack(alignment: .leading, spacing: 24) {
                    if trimmed.isEmpty {
                        if !history.recent.isEmpty { IPARecentShelf() }
                        if index.entries.isEmpty {
                            Text("Libraries are loading. Pull to refresh if they don’t appear.").ipaFont(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 35)
                        } else { LazyVStack(alignment: .leading, spacing: 12) {
                            Text("Browse").ipaFont(.title2, weight: .medium)
                            IPAPagedAppRows(entries: index.entries).id("browse")
                        } }
                    } else if searching && results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 35)
                    } else if results.isEmpty {
                        IPAEmptyState(title: "No Results", subtitle: "Try another app, developer or library.", symbol: "magnifyingglass")
                    } else {
                        LazyVStack(spacing: 0) {
                            IPAPagedAppRows(entries: results).id(trimmed)
                        }
                    }
                    }.padding(.horizontal, 20).padding(.bottom, 24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    } header: {
                        HStack(spacing: 6) {
                            IPACatalogSearchField(text: $query, editing: $editingSearch).frame(height: 52)
                            if editingSearch {
                                IPACloseSearchButton(label: "Dismiss keyboard") {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }
                }
            }.background(IPAStyle.canvas).navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .scrollDismissesKeyboard(.interactively)
                .onDisappear {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .task(id: "\(index.revision)|\(trimmed)") {
                    let text = trimmed
                    guard !text.isEmpty else { results = []; searching = false; return }
                    searching = true
                    do {
                        try await Task.sleep(nanoseconds: 150_000_000)
                        let matches = await index.search(text)
                        try Task.checkCancellation()
                        results = matches; searching = false
                    } catch { }
                }
                .onReceive(NotificationCenter.default.publisher(for: .ipaSearchTabReselected)) { _ in
                    withAnimation(IPAMotion.state(reduced: reduceMotion)) { proxy.scrollTo("ipa-search-top", anchor: .top) }
                }
                .refreshable {
                    async let subscriptions: Void = catalog.refreshAllSources()
                    async let suggestions: Void = discovery.load(force: true)
                    _ = await (subscriptions, suggestions)
                }
            }
        }
    }
}

struct IPAProductView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .subheadline) private var minimumFactWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .subheadline) private var factHeight: CGFloat = 84
    let entry: IPAAppEntry
    @State private var selectedVariantID: String?
    @State private var selectedVersionID: String?
    @State private var listing: IPAProductMetadata?
    @State private var compactHeader = false
    @State private var failedHero: [URL]?
    @EnvironmentObject private var index: IPAAllAppsIndex
    private var currentEntry: IPAAppEntry { index.entry(identifier: entry.id) ?? entry }
    private var variant: IPAAppVariant { IPAProductSelection.variant(in: currentEntry, origin: entry.primary, selected: selectedVariantID) }
    private var app: AltStoreSourceApp {
        if let version = IPAProductSelection.version(in: variant, selected: selectedVersionID) { return variant.app.selecting(version) }
        return variant.app
    }
    private var installVariant: IPAAppVariant { IPAAppVariant(app: app, store: variant.store) }
    private var latestRelease: AltStoreSourceAppVersion? { variant.app.latestVersion }
    private var releaseNotes: String? { IPAReleaseNotes.latest(in: variant.app) }
    private var screenshots: [URL] { app.screenshots.isEmpty ? listing?.screenshots ?? [] : app.screenshots }
    private var heroCandidates: [URL] {
        let preferred = screenshots.first { url in
            let path = url.path.lowercased()
            return !["login", "sign-in", "signin"].contains { path.contains($0) }
        } ?? screenshots.first
        return [app.headerURL, preferred].compactMap { $0 }
    }
    private var hasHero: Bool { !heroCandidates.isEmpty && heroCandidates != failedHero }
    private var storeRating: (score: Double, count: Int)? {
        guard let score = listing?.rating, let count = listing?.ratingCount, count > 0 else { return nil }
        return (score, count)
    }
    private var moreByPublisher: [IPAAppEntry] { index.more(in: variant.store.id, excluding: entry.id) }
    private var recommendations: [IPAAppEntry] { index.similar(to: entry, excluding: moreByPublisher) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if hasHero {
                    IPAProductHero(urls: heroCandidates) { failedHero = heroCandidates }
                        .padding(.horizontal, -20).padding(.bottom, 8)
                }
                HStack(alignment: .top, spacing: 16) {
                    IPARemoteImage(url: app.iconURL, pixels: 360, fallbackURLs: [listing?.icon].compactMap { $0 }, showsPlaceholder: false)
                        .frame(width: 118, height: 118).clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.name).ipaFont(.title2, weight: .bold).lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2).fixedSize(horizontal: false, vertical: true)
                        if let subtitle = app.subtitle ?? app.developerName {
                            Text(subtitle).ipaFont(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        productActions
                    }.frame(minHeight: 118, alignment: .topLeading)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.bottom, 20)
                    .onGeometryChange(for: Bool.self) { geometry in
                        geometry.frame(in: .named("productScroll")).maxY < 44
                    } action: { hidden in
                        withAnimation(IPAMotion.state(reduced: reduceMotion)) { compactHeader = hidden }
                    }
                if !facts.isEmpty {
                    Divider()
                    informationStrip.padding(.vertical, 12)
                }
                if let notes = releaseNotes {
                    if !facts.isEmpty { Divider() }
                    whatsNew(notes)
                }
                if !screenshots.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Preview").ipaFont(.title2, weight: .bold).accessibilityAddTraits(.isHeader)
                        IPAProductScreenshots(urls: Array(screenshots.prefix(12)))
                            .accessibilityLabel("App screenshots")
                    }.padding(.vertical, 14)
                }
                let description = IPACatalogPresentation.displayValue(app.description)
                if let description {
                    IPAExpandableText(text: description, lines: 3).padding(.vertical, 14)
                }
                if !screenshots.isEmpty || description != nil { Divider() }
                NavigationLink { IPAStorePage(reference: variant.store) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: IPAStyle.storeSymbol).ipaFont(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(variant.store.name).ipaFont(.subheadline, weight: .semibold).lineLimit(2)
                            Text("This app’s library").ipaFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").ipaFont(.footnote, weight: .semibold)
                    }.padding(.vertical, 14)
                }.buttonStyle(IPAControlPressStyle(scale: 0.985)).foregroundStyle(.tint)
                if let score = storeRating {
                    ratingsSection(score: score.score, count: score.count)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Information").ipaFont(.title2, weight: .bold).padding(.bottom, 8)
                    if let developer = IPACatalogPresentation.displayValue(app.developerName) { information("Developer", developer) }
                    if let version = IPACatalogPresentation.displayValue(app.latestVersion?.version) { information("Version", version) }
                    if let size = app.latestVersion?.size, size > 0 { information("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    information("Category", listing?.category ?? IPACatalogPresentation.category(for: app))
                    if let minimum = IPACatalogPresentation.displayValue(app.latestVersion?.minOSVersion) { information("Compatibility", "\(minimum)+", symbol: "iphone") }
                    if let maximum = IPACatalogPresentation.displayValue(app.latestVersion?.maxOSVersion) { information("Supported Through", maximum, symbol: "iphone") }
                    if let listing, !listing.languages.isEmpty { information("Languages", listing.languages.compactMap { Locale.current.localizedString(forLanguageCode: $0) }.joined(separator: ", ")) }
                    if let listingURL = listing?.listing {
                        Link(destination: listingURL) {
                            HStack {
                                Text("App Store Listing")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }.ipaFont(.subheadline).padding(.vertical, 12).contentShape(Rectangle())
                        }
                    }
                }.padding(.vertical, 20)
                if IPACompatibility.requiresJIT(identifier: app.bundleIdentifier, declared: app.requiresJIT) {
                    Label("Additional Runtime Required", systemImage: "cpu").ipaFont(.headline, weight: .semibold)
                    Text("This app needs JIT and a compatible launch setup. Check its publisher’s guide before installing.").ipaFont(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if !moreByPublisher.isEmpty { IPACategoryShelf(category: .init(name: "More from \(variant.store.name)", apps: moreByPublisher), library: variant.store).padding(.vertical, 20) }
                if !recommendations.isEmpty { IPACategoryShelf(category: .init(name: "You Might Also Like", apps: recommendations)).padding(.top, 20).padding(.bottom, 4) }
            }.frame(maxWidth: 720, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 4).frame(maxWidth: .infinity)

        }.scrollBounceBehavior(.always, axes: .vertical)
            .modifier(IPAProductScrollEdges())
            .background(IPAStyle.productCanvas)
            .ipaNativePage()
            .coordinateSpace(name: "productScroll")
            .ignoresSafeArea(.container, edges: hasHero ? .top : [])
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarBackground(compactHeader ? .visible : .hidden, for: .navigationBar)
            .toolbar { productToolbar }
            .onAppear { IPAActivityHistory.shared.viewed(entry) }
            .task(id: app.bundleIdentifier) {
                let identifier = app.bundleIdentifier
                let value = await IPAProductMetadataResolver.shared.resolve(identifier)
                if !Task.isCancelled, app.bundleIdentifier == identifier { listing = value }
            }
    }
    private func whatsNew(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What’s New").ipaFont(.title2, weight: .bold).accessibilityAddTraits(.isHeader)
            HStack {
                Text("Version \(latestRelease?.version ?? "—")")
                Spacer()
                if let date = latestRelease?.releaseDate {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated)).lineLimit(1)
                }
            }.ipaFont(.subheadline).foregroundStyle(.secondary)
            IPAExpandableText(text: notes, lines: 3)
        }.padding(.vertical, 18)
    }

    private func ratingsSection(score: Double, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ratings & Reviews").ipaFont(.title2, weight: .bold).accessibilityAddTraits(.isHeader)
            HStack(alignment: .center, spacing: 18) {
                Text(score, format: .number.precision(.fractionLength(1)))
                    .ipaFont(.largeTitle, weight: .bold).monospacedDigit()
                VStack(alignment: .leading, spacing: 4) {
                    IPARatingStars(rating: score)
                    Text(count.formatted() + (count == 1 ? " rating" : " ratings"))
                        .ipaFont(.subheadline).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel("\(score.formatted(.number.precision(.fractionLength(1)))) out of 5, \(count.formatted()) ratings")
            if let url = listing?.listing {
                Link(destination: url) {
                    Label("Read reviews on the App Store", systemImage: "arrow.up.right")
                        .ipaFont(.subheadline, weight: .semibold)
                }
            }
        }.padding(.vertical, 18)
    }

    private var productActions: some View {
        IPAProductActions(variant: installVariant, showsVersions: currentEntry.variants.count > 1 || variant.app.versions.count > 1) { versionMenu }
    }
    @ToolbarContentBuilder private var productToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            IPAArtwork(url: app.iconURL ?? listing?.icon, size: 30)
                .opacity(compactHeader ? 1 : 0).accessibilityHidden(true)
        }
        if compactHeader {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) {
                    IPAGetButton(variant: installVariant, alwaysFilled: true)
                }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { IPAGetButton(variant: installVariant, alwaysFilled: true) }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: app.latestVersion?.downloadURL ?? variant.store.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .tint(.primary).accessibilityLabel("Share app")
            }
        }
    }

    private var versionMenu: some View {
        Menu {
            if currentEntry.variants.count > 1 {
                Section("Library & Edition") {
                    ForEach(currentEntry.variants) { option in
                        Button { selectedVariantID = IPAProductSelection.variantKey(option); selectedVersionID = nil } label: {
                            if IPAProductSelection.variantKey(option) == IPAProductSelection.variantKey(variant) { Label("\(option.edition) · \(option.store.name)", systemImage: "checkmark") }
                            else { Text("\(option.edition) · \(option.store.name)") }
                        }
                    }
                }
            }
            if !variant.app.versions.isEmpty {
                Section("Version") {
                    ForEach(variant.app.versions) { version in
                        Button { selectedVersionID = IPAProductSelection.versionKey(version) } label: {
                            if IPAProductSelection.versionKey(version) == app.latestVersion.map(IPAProductSelection.versionKey) { Label(version.version, systemImage: "checkmark") }
                            else { Text(version.version) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(app.latestVersion?.version ?? variant.edition).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").ipaFont(.caption2, weight: .semibold)
            }.ipaFont(.subheadline, weight: .semibold).contentTransition(.opacity)
                .padding(.horizontal, 12).frame(minHeight: 34)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }.buttonStyle(IPAControlPressStyle())
            .accessibilityLabel("Choose version and edition")
            .accessibilityValue("\(app.latestVersion?.version ?? variant.edition), \(variant.store.name)")
    }
    private struct Fact: Identifiable {
        let title: String
        let value: String
        var symbol: String?
        var caption: String?
        var rating: Double?
        var id: String { title }
    }
    private var facts: [Fact] {
        var values: [Fact] = []
        if let rating = storeRating {
            values.append(.init(title: "\(rating.count.formatted(.number.notation(.compactName))) RATINGS",
                                value: rating.score.formatted(.number.precision(.fractionLength(1))), rating: rating.score))
        }
        if let age = IPACatalogPresentation.displayValue(listing?.ageRating) { values.append(.init(title: "AGE RATING", value: age, caption: "Years Old")) }
        if let developer = IPACatalogPresentation.displayValue(app.developerName) { values.append(.init(title: "DEVELOPER", value: developer, symbol: "person.crop.square")) }
        if let bytes = app.latestVersion?.size, bytes > 0 { values.append(.init(title: "SIZE", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), symbol: "arrow.down.circle")) }
        if let version = IPACatalogPresentation.displayValue(app.latestVersion?.version) { values.append(.init(title: "VERSION", value: version, symbol: "app.badge")) }
        if let minimum = IPACatalogPresentation.displayValue(app.latestVersion?.minOSVersion) { values.append(.init(title: "COMPATIBILITY", value: "\(minimum)+", symbol: "iphone")) }
        return values
    }
    private var informationStrip: some View {
        GeometryReader { geometry in
            let columns = facts
            let width = max(minimumFactWidth, geometry.size.width / CGFloat(max(1, min(4, columns.count))))
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(columns) { fact in
                        let isDeveloper = fact.title == "DEVELOPER"
                        VStack(spacing: 5) {
                            Text(fact.title).ipaFont(.caption2, weight: .medium)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            if isDeveloper, let symbol = fact.symbol {
                                Image(systemName: symbol).ipaFont(.title2).accessibilityHidden(true)
                            }
                            Text(fact.value).ipaFont(isDeveloper ? .caption : .title3, weight: .semibold)
                                .lineLimit(isDeveloper ? 2 : 1).minimumScaleFactor(0.8)
                            if let rating = fact.rating {
                                IPARatingStars(rating: rating, size: 11)
                            } else if !isDeveloper, let symbol = fact.symbol {
                                Image(systemName: symbol).ipaFont(.caption).accessibilityHidden(true)
                            }
                            if let caption = fact.caption { Text(caption).ipaFont(.caption).lineLimit(1) }
                        }
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                        .frame(width: width, height: factHeight)
                        .overlay(alignment: .trailing) {
                            if fact.id != columns.last?.id {
                                Rectangle().fill(.primary.opacity(0.16))
                                    .frame(width: 1 / max(1, displayScale), height: factHeight * 0.55)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(minWidth: geometry.size.width)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(height: factHeight)
    }
    @ViewBuilder private func information(_ label: String, _ value: String, symbol: String? = nil) -> some View {
        if let value = IPACatalogPresentation.displayValue(value) { VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 8); if let symbol { Label(value, systemImage: symbol).lineLimit(1) } else { Text(value).multilineTextAlignment(.trailing).lineLimit(3) } }.ipaFont(.subheadline).padding(.vertical, 12)
            Divider()
        } }
    }
}

private struct IPARatingStars: View {
    let rating: Double
    var size: CGFloat = 14

    var body: some View {
        let halves = Int((min(5, max(0, rating)) * 2).rounded())
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                let fill = halves - 2 * index
                Image(systemName: fill >= 2 ? "star.fill" : fill == 1 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: size, weight: .semibold))
            }
        }.accessibilityHidden(true)
    }
}

// Keep download progress updates inside the controls rather than rebuilding the
// entire product description, artwork and recommendation shelves on every tick.
private struct IPAProductActions<VersionMenu: View>: View {
    let variant: IPAAppVariant
    let showsVersions: Bool
    @ViewBuilder let versionMenu: () -> VersionMenu
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    @AppStorage("IPAInstallMode") private var mode = "container"
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) { buttons }
        } else { HStack(spacing: 8) { buttons } }
    }
    @ViewBuilder private var buttons: some View {
        IPAGetButton(variant: variant, showsStatus: true, alwaysFilled: true)
            .fixedSize(horizontal: true, vertical: false).layoutPriority(1)
        if showsVersions, installer.job(for: variant, independent: mode == "independent") == nil { versionMenu() }
    }
}

private struct IPAProductScrollEdges: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else { content }
    }
}

private struct IPAProductHero: View {
    let urls: [URL]
    let onFailure: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let pull = reduceMotion ? 0 : max(0, geometry.frame(in: .named("productScroll")).minY)
            let size = CGSize(width: geometry.size.width, height: geometry.size.height + pull)
            artwork(size: size, onFailure: onFailure)
                .overlay(alignment: .top) {
                    if !reduceTransparency {
                        artwork(size: size)
                            .blur(radius: 9, opaque: true)
                            .mask(alignment: .top) {
                                LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black.opacity(0.85), location: 0.48),
                                    .init(color: .clear, location: 1)
                                ], startPoint: .top, endPoint: .bottom)
                                .frame(height: 52)
                            }
                    }
                }
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(reduceTransparency ? 0.64 : 0.28), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 64)
                }
                .offset(y: -pull)
        }.aspectRatio(16 / 9, contentMode: .fit).accessibilityHidden(true)
    }

    private func artwork(size: CGSize, onFailure: (() -> Void)? = nil) -> some View {
        IPARemoteImage(url: urls.first, pixels: 1200, fallbackURLs: Array(urls.dropFirst()),
                       showsPlaceholder: false, onFailure: onFailure)
            .frame(width: size.width, height: size.height).clipped()
    }
}

private struct IPAProductScreenshots: View {
    let urls: [URL]
    @State private var viewport: CGFloat = 320
    @State private var aspects: [URL: CGFloat] = [:]
    private let heightLimit: CGFloat = 380
    private var rowHeight: CGFloat {
        urls.compactMap { aspects[$0] }.map { min(heightLimit, viewport / $0) }.max()
            ?? min(heightLimit, viewport * 9 / 16)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(urls, id: \.self) { url in
                    IPAProductScreenshot(url: url, maximumWidth: viewport, maximumHeight: heightLimit,
                                         aspect: aspects[url] ?? 16 / 9) { aspect in
                        if aspects[url] != aspect { aspects[url] = aspect }
                    }
                }
            }.scrollTargetLayout()
        }
        .frame(height: rowHeight).scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned).scrollClipDisabled()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = max(1, $0) }
    }
}

private struct IPAProductScreenshot: View {
    let url: URL
    let maximumWidth: CGFloat
    let maximumHeight: CGFloat
    let aspect: CGFloat
    let onAspect: (CGFloat) -> Void
    @State private var previewing = false
    private var width: CGFloat { min(maximumWidth, maximumHeight * aspect) }
    var body: some View {
        Button { previewing = true } label: {
            IPARemoteImage(url: url, pixels: 900, mode: .fit, showsPlaceholder: false, onSize: { size in
                guard size.width > 0, size.height > 0 else { return }
                onAspect(size.width / size.height)
            }).frame(width: width, height: min(maximumHeight, width / aspect))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityLabel("Open screenshot")
            .sheet(isPresented: $previewing) {
                NavigationStack {
                    IPAScreenshotPage(url: url)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { previewing = false } } }
                }.presentationDragIndicator(.visible).modifier(IPATheme())
            }
    }
}
private struct IPAScreenshotPage: View {
    let url: URL
    var body: some View {
        GeometryReader { geometry in
            IPARemoteImage(url: url, pixels: 1600, mode: .fit, showsPlaceholder: false).frame(width: geometry.size.width, height: geometry.size.height)
        }.background(IPAStyle.canvas).navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}


struct IPASettingsView: View {
    @State private var navigationID = UUID()
    @AppStorage("IPAInstallMode") private var mode = "container"
    @State private var showWelcome = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    IPATabHeading("Settings")
                    IPASigningHero()
                    IPASettingsGroup(title: nil) {
                        IPAMethodSelector()
                    }
                    IPASettingsGroup(title: nil) {
                        NavigationLink { IPASigningOptionsView() } label: { IPASettingsRow("Signing Options", subtitle: "App features and compatibility", symbol: "signature", color: .indigo) }
                        IPASettingsDivider()
                        NavigationLink { IPARuntimeSettingsView() } label: { IPASettingsRow("App Behavior", subtitle: "Launch and advanced tools", symbol: "square.grid.2x2.fill", color: .orange) }
                    }
                    IPASettingsGroup(title: nil) {
                        NavigationLink { IPAAppearanceView() } label: { IPASettingsRow("Appearance", subtitle: "Theme, accent and typography", symbol: "paintpalette.fill", color: .purple) }
                        IPASettingsDivider()
                        NavigationLink { IPAStorageSettingsView() } label: { IPASettingsRow("Storage & Files", subtitle: "App data, artwork and tweaks", symbol: "internaldrive.fill", color: .gray) }
                        IPASettingsDivider()
                        NavigationLink { IPAHistoryList(downloaded: true) } label: { IPASettingsRow("Download History", subtitle: "Everything you’ve added", symbol: "clock.arrow.circlepath", color: .teal) }
                        IPASettingsDivider()
                        NavigationLink { IPAUpdatesView() } label: { IPASettingsRow("iPAStore Updates", subtitle: "Check for the newest version", symbol: "arrow.triangle.2.circlepath", color: .blue) }
                    }
                    IPASettingsGroup(title: nil) {
                        Link(destination: URL(string: "https://discord.gg/EQ77PXQQgt")!) { IPASettingsRow("Community", subtitle: "Help, ideas and updates", symbol: "bubble.left.and.bubble.right.fill", color: .mint) }
                        IPASettingsDivider()
                        NavigationLink { IPAHowItWorksView() } label: { IPASettingsRow("How iPAStore Works", subtitle: "Installing and signing", symbol: "book.closed.fill", color: .purple) }
                        IPASettingsDivider()
                        Button { showWelcome = true } label: { IPASettingsRow("Open Welcome", subtitle: "Revisit the setup guide", symbol: "hand.wave.fill", color: .indigo) }
                    }
                    IPASettingsGroup(title: nil) {
                        NavigationLink { IPAPrivacyView() } label: { IPASettingsRow("Privacy & Compatibility", symbol: "hand.raised.fill", color: .cyan) }
                        IPASettingsDivider()
                        NavigationLink { IPALicensesView() } label: { IPASettingsRow("Credits & Licenses", symbol: "doc.text.fill", color: .gray) }
                    }
                    Text("iPAStore · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                        .ipaFont(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.bottom, 15)
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.background(IPAStyle.canvas).navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .fullScreenCover(isPresented: $showWelcome) { IPAWelcomeView { showWelcome = false }.modifier(IPATheme()) }
        }.id(navigationID)
            .onReceive(NotificationCenter.default.publisher(for: .ipaOpenSettings)) { _ in
                showWelcome = false; navigationID = UUID()
            }
    }
}

struct IPAFreeSetupView: View {
    var finish: (() -> Void)? = nil
    @StateObject private var state = IPASigningState()
    private var ready: Bool { state.freeSetupComplete }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                IPASetupHeading(symbol: IPASetupSymbols.free, title: "Free signing for your iPhone.", subtitle: "Your apps live inside iPAStore. Refresh iPAStore every 7 days to keep them ready.")
                VStack(alignment: .leading, spacing: 20) {
                    IPASetupStep(number: "1", title: "Pair your iPhone", detail: "Approve pairing or import this iPhone’s pairing file.")
                    IPASetupStep(number: "2", title: "Verify your connection", detail: "Enable the local VPN and verify the connection in Manage.")
                    IPASetupStep(number: "3", title: "Connect your account", detail: "Sign in securely with your Apple Account, then finish setup.")
                }.padding(22).background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 24))
                NavigationLink { IPASigningSetupPage(state: state) } label: {
                    IPASetupActionLabel(title: "Manage", symbol: IPASetupSymbols.manage)
                }.buttonStyle(.plain)
                if let finish {
                    Button(ready ? "Start Using iPAStore" : "Finish Later", action: finish)
                        .buttonStyle(IPAPillStyle(prominent: true, compact: true))
                        .frame(maxWidth: .infinity)
                } else {
                    NavigationLink("Renewal & Reminders") { IPARenewalPreferencesView() }
                        .ipaFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.plain)
                }
                Text("iOS 27 or later supports pairing on this iPhone. You’ll approve system prompts and enable a local connection. iOS controls background refresh timing.").ipaFont(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }.background(IPAStyle.canvas).navigationTitle("").navigationBarTitleDisplayMode(.inline).onAppear { state.importInteractiveReadiness(); state.reload() }
    }
}

struct IPAStorageSettingsView: View {
    var body: some View {
        Form {
            Section { NavigationLink("Artwork Cache") { IPAArtworkStorageView() } }
            #if !IPASTORE_PREVIEW
            Section {
                NavigationLink("App & Container Data") { LCDataManagementView() }
                NavigationLink("Tweaks & Extensions") { LCTweaksView() }
            } footer: { Text("Manage downloaded apps and their data separately from temporary library artwork.") }
            #endif
        }.navigationTitle("Storage").navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}

struct IPARuntimeSettingsView: View {
    @AppStorage("LCFrameShortcutIcons") private var frameIcons = false
    @AppStorage("LCSwitchAppWithoutAsking") private var silentSwitch = false
    @AppStorage("LCOpenWebPageWithoutAsking") private var silentWeb = false
    @AppStorage("LCKeepSelectedWhenQuit") private var keepSelected = false
    #if !IPASTORE_PREVIEW
    @AppStorage("LCJITEnablerType", store: LCUtils.appGroupUserDefault) private var enabler: JITEnablerType = .SideJITServer
    @AppStorage("LCSideJITServerAddress", store: LCUtils.appGroupUserDefault) private var server = ""
    @AppStorage("LCDeviceUDID", store: LCUtils.appGroupUserDefault) private var udid = ""
    #endif
    var body: some View {
        Form {
            Section {
                Toggle("Frame Home Screen Shortcuts", isOn: $frameIcons)
                Toggle("Switch Apps Without Asking", isOn: $silentSwitch)
                Toggle("Open Web Links Without Asking", isOn: $silentWeb)
                Toggle("Keep Last App Selected", isOn: $keepSelected)
            } header: { Text("Container Apps") } footer: { Text("These options apply to apps running inside iPAStore. Standalone apps use their own iOS settings. Leave link confirmations enabled if you want to review requests from imported apps.") }
            #if !IPASTORE_PREVIEW
            Section {
                Picker("JIT Provider", selection: $enabler) { ForEach(JITEnablerType.allCases) { Text($0.displayName).tag($0) } }
                if enabler == .SideJITServer || enabler == .JITStreamerEBLegacy {
                    TextField("Server Address", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if enabler == .SideJITServer { TextField("Device UDID", text: $udid).textInputAutocapitalization(.never).autocorrectionDisabled() }
            } header: { Text("JIT") } footer: { Text("Select the provider you have configured. Choosing one does not enable JIT by itself; each app’s runtime requirements still apply.") }
            Section {
                NavigationLink("Multitasking") { LCMultitaskSettingView() }
                NavigationLink("Multiple Containers") { LCMultiLCManagementView() }
                NavigationLink("Certificate Diagnostics") { LCJITLessDiagnoseView() }
            } header: { Text("Advanced") }
            #else
            Section { Text("JIT, multitasking and container diagnostics are available in the complete iPhone build.").foregroundStyle(.secondary) }
            #endif
        }.navigationTitle("Apps & Runtime").navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}

struct IPASignButton: View {
    var title = "Sign Now"
    var compact = false
    var prominent = false
    @ObservedObject private var renewal = IPARenewalManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var message: String?
    @State private var signed = false
    var body: some View {
        Button {
            Task {
                signed = false
                let success = await renewal.signNow()
                withAnimation(IPAMotion.state(reduced: reduceMotion)) { signed = success }
                message = success ? IPARenewalPolicy.successMessage(profile: renewal.profile) : renewal.lastFailure ?? "Signing could not finish. Check Signing Setup and try again."
            }
        } label: {
            if prominent {
                IPASetupActionLabel(title: renewal.working ? "Signing…" : title, symbol: renewal.working ? nil : "signature")
                    .overlay(alignment: .leading) { if renewal.working { ProgressView().scaleEffect(0.7).padding(.leading, 8).tint(.white) } }
            } else {
                Label(renewal.working ? "Signing…" : title, systemImage: "signature").ipaFont(.subheadline, weight: .semibold)
            }
        }.buttonStyle(.plain).disabled(renewal.working || IPASigningState.certificateCheckRunning || !IPASigningState().freeSetupComplete)
            .animation(IPAMotion.state(reduced: reduceMotion), value: renewal.working)
            .alert(signed ? "iPAStore Signed" : "Signing Couldn’t Finish", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }
}

struct IPAPrivacyView: View {
    var body: some View {
        List {
            Section("Your Data") { Text("Library choices and recent searches stay on this device. iPAStore does not add libraries without your choice. Loading a library contacts its publisher for app information and artwork.") }
            Section("Signing") { Text("Signing uses your Apple Account and a device pairing record. Keep pairing files private. Credentials, certificates and pairing records are not included when iPAStore is packaged for distribution.") }
            Section("App Compatibility") { Text("Apps imported into iPAStore use a shared container runtime. Features such as extensions, notifications, JIT and protected content may behave differently or be unavailable. A library listing is not a guarantee of compatibility.") }
            Section("Renewal") { Text("Automatic renewal is a best-effort background task. iOS scheduling, connection availability, account state and installation limits affect whether it completes. Check the actual expiration and signing result in Settings → Manage.") }
        }.navigationTitle("Privacy & Compatibility").navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}

struct IPALicensesView: View {
    var body: some View {
        List {
            Section("iPAStore") {
                Text("An independent project built on open-source work. No warranty is provided. Source and license terms must accompany distributed builds.")
                NavigationLink("Read Bundled License") {
                    ScrollView {
                        Text((Bundle.main.url(forResource: "OpenSourceNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "The full license is included in LICENSE in the source distribution.")
                            .font(.footnote.monospaced()).textSelection(.enabled).padding()
                    }.navigationTitle("License")
                }
            }
            Section("Container engine") {
                Link("LiveContainer · AGPLv3", destination: URL(string: "https://github.com/LiveContainer/LiveContainer")!)
                Link("Full license", destination: URL(string: "https://github.com/LiveContainer/LiveContainer/blob/main/LICENSE")!)
            }
            Section("Signing integration") {
                Link("SideStore · AGPLv3", destination: URL(string: "https://github.com/SideStore/SideStore")!)
            }
            Section("Library Directory & Typography") {
                Link("iOS Hub · MIT", destination: URL(string: "https://github.com/CaseyCZ/iOS-Hub")!)
                NavigationLink("iOS Hub License") { IPABundledNotice(name: "iOSHub-LICENSE", title: "iOS Hub License") }
                Link("Monocraft · OFL 1.1", destination: URL(string: "https://github.com/IdreesInc/Monocraft")!)
                NavigationLink("Font License") { IPABundledNotice(name: "Monocraft-LICENSE", title: "Font License") }
            }
            Section("Standalone Signing") {
                Link("Zsign-Package · GPLv3", destination: URL(string: "https://github.com/khcrysalis/Zsign-Package")!)
                Link("Feather · installation reference", destination: URL(string: "https://github.com/claration/Feather")!)
            }
            Section("Additional components") {
                Text("The source distribution retains upstream acknowledgments and dependency licenses, including fishhook, litehook, OpenSSL and ZSign. Review UPSTREAM.md before redistribution.")
            }
        }.navigationTitle("Open-Source Licenses")
    }
}


#if !IPASTORE_PREVIEW
struct IPAInstalledProductView: View {
    @ObservedObject var app: LCAppModel
    @EnvironmentObject private var index: IPAAllAppsIndex
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    var body: some View {
        Group {
            if let identifier = app.appInfo.bundleIdentifier(), let entry = index.entry(identifier: identifier) {
                IPAProductView(entry: entry)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .top, spacing: 18) {
                            if let image = app.appInfo.iconIsDarkIcon(colorScheme == .dark) { Image(uiImage: image).resizable().scaledToFit().frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 23)) }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(app.displayName).ipaFont(.title2, weight: .bold).lineLimit(2)
                                Text("On this iPhone").ipaFont(.subheadline).foregroundStyle(.secondary)
                                Button("Open") { Task { await installer.open(app.appInfo.bundleIdentifier() ?? "") } }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            }
                        }
                        Divider()
                        LabeledContent("Version", value: app.version)
                        LabeledContent("Identifier", value: app.appInfo.bundleIdentifier() ?? "Unknown").ipaFont(.footnote)
                        Text("This app is available in your iPAStore library. Its publisher hasn’t supplied a matching catalog page.").ipaFont(.subheadline).foregroundStyle(.secondary)
                        NavigationLink("App Settings") { LCAppSettingsView(model: app) }
                    }.padding(20)
                }.background(IPAStyle.canvas).navigationBarTitleDisplayMode(.inline).ipaNativePage()
            }
        }
    }
}
#endif

private struct IPAProductOffset: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct IPAFullTextHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct IPALimitedTextHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct IPAInlineMoreSize: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
private struct IPAInlineLineHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct IPAExpandableText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let text: String
    let lines: Int
    private let preview: String
    private let capped: Bool
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0
    @State private var measuredLineHeight: CGFloat = 0
    @State private var moreSize = CGSize.zero
    @ScaledMetric(relativeTo: .body) private var fallbackLineHeight = 22.0
    @ScaledMetric(relativeTo: .body) private var fadeWidth = 24.0
    init(text: String, lines: Int = 4) {
        self.text = text; self.lines = max(1, lines)
        preview = String(text.prefix(1600))
        capped = preview.utf8.count < text.utf8.count
    }
    private var truncated: Bool { capped || fullHeight > limitedHeight + 1 }
    private var lineHeight: CGFloat { measuredLineHeight > 0 ? measuredLineHeight : fallbackLineHeight }
    private var tapPadding: CGFloat { max(0, 44 - lineHeight) / 2 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(expanded ? text : preview).ipaFont(.body).lineLimit(expanded ? nil : lines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in Color.clear.preference(key: IPALimitedTextHeight.self, value: geometry.size.height) })
                .mask { disclosureMask }
                .overlay(alignment: .topLeading) {
                    // Bound collapsed measurement; full content is laid out only
                    // when requested. Hidden probes never enter accessibility.
                    Text(preview).ipaFont(.body).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { geometry in Color.clear.preference(key: IPAFullTextHeight.self, value: geometry.size.height) })
                        .hidden().accessibilityHidden(true).allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    Text("Ag").ipaFont(.body).fixedSize()
                        .background(GeometryReader { geometry in Color.clear.preference(key: IPAInlineLineHeight.self, value: geometry.size.height) })
                        .hidden().accessibilityHidden(true).allowsHitTesting(false)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !expanded && truncated { moreButton }
                }
            if expanded {
                Button("Less") { toggle() }.ipaFont(.body).foregroundStyle(.tint)
                    .buttonStyle(IPAControlPressStyle()).accessibilityLabel("Show less")
            }
        }
        .onPreferenceChange(IPAFullTextHeight.self) { if abs(fullHeight - $0) > 0.5 { fullHeight = $0 } }
        .onPreferenceChange(IPALimitedTextHeight.self) { if !expanded, abs(limitedHeight - $0) > 0.5 { limitedHeight = $0 } }
        .onPreferenceChange(IPAInlineLineHeight.self) { if $0 > 0, abs(measuredLineHeight - $0) > 0.5 { measuredLineHeight = $0 } }
        .onPreferenceChange(IPAInlineMoreSize.self) { if $0.width > 0, moreSize != $0 { moreSize = $0 } }
        .onChange(of: text) { _, _ in expanded = false }
    }
    @ViewBuilder private var disclosureMask: some View {
        if !expanded && truncated {
            VStack(spacing: 0) {
                Color.black
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: UnitPoint(x: layoutDirection == .rightToLeft ? 1 : 0, y: 0.5), endPoint: UnitPoint(x: layoutDirection == .rightToLeft ? 0 : 1, y: 0.5)).frame(width: fadeWidth)
                    Color.clear.frame(width: max(44, moreSize.width))
                }.frame(height: lineHeight)
            }
        } else { Color.black }
    }
    private var moreButton: some View {
        Button { toggle() } label: {
            Text("more").ipaFont(.body).lineLimit(1).fixedSize()
                .padding(.leading, 4).frame(minWidth: 44, minHeight: lineHeight, alignment: .trailing)
                .padding(.vertical, tapPadding)
                .background(GeometryReader { geometry in Color.clear.preference(key: IPAInlineMoreSize.self, value: geometry.size) })
                .contentShape(Rectangle())
        }.foregroundStyle(.tint).buttonStyle(IPAControlPressStyle())
            // Expand the hit area to44pt without moving the text's last baseline.
            .offset(y: tapPadding).accessibilityLabel("Show more")
    }
    private func toggle() {
        withAnimation(reduceMotion ? nil : IPAMotion.state(reduced: false)) { expanded.toggle() }
    }
}

struct IPABundledNotice: View {
    let name: String
    let title: String
    var body: some View {
        ScrollView { Text(Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The license is included in the source distribution.").font(.footnote.monospaced()).textSelection(.enabled).padding(20) }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}

// Lazy rows alone still make SwiftUI reconcile every catalog identifier. Grow
// the visible slice as the reader approaches its end; all results remain reachable.
struct IPAPagedAppRows: View {
    let entries: [IPAAppEntry]
    @State private var count = 100
    var body: some View {
        ForEach(Array(entries.prefix(count))) { entry in
            IPAAppRow(entry: entry)
            Divider().padding(.leading, 72)
        }
        if count < entries.count {
            Color.clear.frame(height: 1).onAppear { count = min(entries.count, count + 100) }
        }
    }
}



// Native presentations supply their own interruptible motion and Reduce Motion
// behavior. Avoid imposing a page push on a temporary browser task.
struct IPAWebLink<Label: View>: View {
    let destination: URL
    @ViewBuilder var label: () -> Label
    @State private var browsing = false
    var body: some View {
        if ["https", "http"].contains(destination.scheme?.lowercased() ?? "") {
            Button { browsing = true } label: { label() }
                .sheet(isPresented: $browsing) {
                    IPAWebBrowser(url: destination).ignoresSafeArea().presentationDragIndicator(.visible)
                }
        } else { Link(destination: destination, label: label) }
    }
}
private struct IPAWebBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .done
        return browser
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) { }
}

extension Notification.Name {
    static let ipaOpenSettings = Notification.Name("iPAStore.OpenSettings")
}
@MainActor enum IPASettingsNavigation {
    static func open() {
        DataManager.shared.model.selectedTab = .settings
        NotificationCenter.default.post(name: .ipaOpenSettings, object: nil)
    }
}
