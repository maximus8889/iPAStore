import SwiftUI

@MainActor final class IPADiscovery: ObservableObject {
    @Published private(set) var sources: [String: AltStoreSource] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var loadingIDs = Set<String>()
    @Published private(set) var featured: IPAStoreSuggestion?
    private let dailyChoice: IPADailyLibraryChoice
    private var cachedAt: [String: Date] = [:]
    private var cacheRestored = false
    private let suggestions: [IPAStoreSuggestion]
    private let suggestionsByURL: [String: IPAStoreSuggestion]
    private let cache: URL?
    private let legacyCache: URL?
    private let loader: @Sendable (URL) async throws -> (AltStoreSource, Data)
    private var allWork: Task<Void, Never>?
    private var requests: [String: Task<Void, Never>] = [:]
    private var forceQueued = false
    private var runningStalePass = false
    private var retryAt: [String: Date] = [:]
    private var cacheLoaded = false
    private var cacheWork: Task<Void, Never>?
    static let refreshInterval: TimeInterval = 900
    init(suggestions: [IPAStoreSuggestion] = IPAStoreDirectory.suggestions, cacheDirectory: URL? = nil, defaults: UserDefaults = .standard,
         loader: @escaping @Sendable (URL) async throws -> (AltStoreSource, Data) = { try await IPACatalogDownloads.shared.load(from: $0) }) {
        self.dailyChoice = IPADailyLibraryChoice(defaults: defaults)
        self.suggestions = suggestions; self.loader = loader
        self.suggestionsByURL = Dictionary(suggestions.map { (AltStoreSourceLoader.canonical($0.url), $0) }, uniquingKeysWith: { a, _ in a })
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        cache = cacheDirectory ?? base?.appendingPathComponent("AltStoreSourceCache", isDirectory: true)
        legacyCache = cacheDirectory == nil ? base?.appendingPathComponent("IPAStoreDiscovery", isDirectory: true) : nil
        let candidates = suggestions.filter { !$0.marketplaceOnly }
        if let id = dailyChoice.saved(on: Date(), candidates: candidates.map(\.id)) { featured = candidates.first { $0.id == id } }
    }
    func updateFeatured(on date: Date = Date()) {
        let candidates = suggestions.filter { !$0.marketplaceOnly }
        let eligible = Set(candidates.filter { sources[$0.id]?.apps.isEmpty == false }.map(\.id))
        guard cacheRestored || !eligible.isEmpty else { return }
        let id = dailyChoice.select(on: date, candidates: candidates.map(\.id), eligible: eligible)
        if featured?.id != id { featured = candidates.first { $0.id == id } }
    }
    var availableSuggestions: [IPAStoreSuggestion] { suggestions.filter { !$0.marketplaceOnly && failures[$0.id] == nil && sources[$0.id]?.apps.isEmpty == false } }
    var libraries: [(IPAStoreReference, [AltStoreSourceApp])] { suggestions.map { (IPAStoreReference($0), sources[$0.id]?.apps ?? []) } }
    var entries: [IPAAppEntry] { IPACatalogPresentation.entries(libraries) }
    func checkedSnapshot(_ snapshot: [String: AltStoreSource]) -> [URL: (AltStoreSource, Date)] {
        Dictionary(suggestions.compactMap { item in
            guard let source = snapshot[item.id], let date = cachedAt[item.id] else { return nil }
            return (item.url, (source, date))
        }, uniquingKeysWith: { a, _ in a })
    }
    func adoptCatalog(_ items: [AltStoreSourcesViewModel.SourceItem]) {
        for item in items {
            guard let source = item.source, let checked = item.lastCheckedAt,
                  let known = suggestionsByURL[AltStoreSourceLoader.canonical(item.url)],
                  checked > (cachedAt[known.id] ?? .distantPast) else { continue }
            cachedAt[known.id] = checked; failures[known.id] = nil
            if sources[known.id]?.id != source.id { sources[known.id] = source }
        }
        updateFeatured()
    }
    private func readCache() async {
        if let cacheWork { await cacheWork.value; return }
        guard !cacheLoaded else { return }
        let directory = cache, legacy = legacyCache
        let candidates = suggestions.filter { !$0.marketplaceOnly }
        let priority = featured ?? IPACatalogPresentation.featuredIndex(on: Date(), count: candidates.count).map { candidates[$0] }
        let remaining = suggestions.filter { $0.id != priority?.id }
        let task = Task { @MainActor in
            // Publish the visible library before decoding all other catalogs.
            // The shared task also prevents concurrent callers skipping restore.
            var priorityRefresh: Task<Void, Never>?
            if let priority {
                let cached = await Task.detached(priority: .userInitiated) {
                    Self.readCached(priority, directory: directory, legacy: legacy)
                }.value
                if let cached { adoptCached([cached]) }
                if sources[priority.id]?.apps.isEmpty != false {
                    priorityRefresh = Task { await refresh(priority) }
                }
            }
            let cached = await Task.detached(priority: .utility) {
                remaining.compactMap { Self.readCached($0, directory: directory, legacy: legacy) }
            }.value
            adoptCached(cached)
            cacheRestored = true; cacheLoaded = true; updateFeatured()
            await priorityRefresh?.value
            cacheWork = nil
        }
        cacheWork = task
        await task.value
    }
    nonisolated private static func readCached(_ item: IPAStoreSuggestion, directory: URL?, legacy: URL?) -> (String, AltStoreSource, Date)? {
        let primary = directory?.appendingPathComponent(AltStoreSourceLoader.cacheFileName(for: item.url))
        let old = legacy?.appendingPathComponent(item.id + ".json")
        for file in [primary, old].compactMap({ $0 }) {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, size <= 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: file), let source = try? AltStoreSourceLoader.decode(from: data, baseURL: item.url) else { continue }
            let date = values.contentModificationDate ?? .distantPast
            return (item.id, source, date <= Date() ? date : .distantPast)
        }
        return nil
    }
    private func adoptCached(_ cached: [(String, AltStoreSource, Date)]) {
        var merged = sources
        var changed = false
        for (id, source, date) in cached where merged[id] == nil {
            merged[id] = source; cachedAt[id] = date; changed = true
        }
        if changed { sources = merged; updateFeatured() }
    }
    func source(for reference: IPAStoreReference) -> AltStoreSource? { reference.suggestion.flatMap { sources[$0.id] } }
    func reload(_ reference: IPAStoreReference, onlyStale: Bool = false) async {
        guard let item = suggestions.first(where: { IPAStoreDirectory.canonical($0.url) == reference.id }) else { return }
        await readCache()
        if onlyStale, sources[item.id] != nil, cachedAt[item.id].map({ Date().timeIntervalSince($0) < Self.refreshInterval }) == true { return }
        await refresh(item)
    }
    private func refresh(_ item: IPAStoreSuggestion) async {
        if let task = requests[item.id] { await task.value; return }
        let task = Task { @MainActor in
            let started = Date()
            loadingIDs.insert(item.id)
            defer { loadingIDs.remove(item.id); requests[item.id] = nil }
            do {
                let (source, data) = try await loader(item.url)
                let checked = Date()
                if let cache {
                    let file = cache.appendingPathComponent(AltStoreSourceLoader.cacheFileName(for: item.url))
                    await IPACatalogCacheWriter.shared.store(data, at: file, checked: checked)
                }
                guard (cachedAt[item.id] ?? .distantPast) <= checked else { return }
                cachedAt[item.id] = checked; failures[item.id] = nil; retryAt[item.id] = nil
                if sources[item.id]?.id != source.id { sources[item.id] = source }
                updateFeatured()
            } catch {
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled && (cachedAt[item.id] ?? .distantPast) <= started {
                    failures[item.id] = AltStoreSourceLoader.refreshMessage(error)
                    retryAt[item.id] = Date().addingTimeInterval(AltStoreSourceLoader.retryDelay(error))
                }
            }
        }
        requests[item.id] = task
        await task.value
    }
    func load(force: Bool = false) async {
        if let allWork {
            if force && runningStalePass { forceQueued = true }
            await allWork.value; return
        }
        runningStalePass = !force; loading = true; forceQueued = false
        let task = Task { @MainActor in
            await readCache()
            repeat {
                if !runningStalePass { forceQueued = false }
                let forcePass = !runningStalePass
                let ordered = featured.map { featured in suggestions.sorted { ($0.id == featured.id ? 0 : 1) < ($1.id == featured.id ? 0 : 1) } } ?? suggestions
                let items = ordered.filter { item in
                    forcePass || (failures[item.id] != nil
                        ? retryAt[item.id].map({ $0 <= Date() }) != false
                        : sources[item.id] == nil || cachedAt[item.id].map({ Date().timeIntervalSince($0) >= Self.refreshInterval }) != false)
                }
                await withTaskGroup(of: Void.self) { group in
                    var remaining = items.makeIterator()
                    for _ in 0..<4 { if let item = remaining.next() { group.addTask { await self.refresh(item) } } }
                    while await group.next() != nil { if let item = remaining.next() { group.addTask { await self.refresh(item) } } }
                }
                runningStalePass = false
            } while forceQueued
            loading = false; allWork = nil
        }
        allWork = task
        await task.value
    }
}

extension AltStoreSourcesViewModel {
    var libraryEntries: [IPAAppEntry] { IPACatalogPresentation.entries(sources.map { (IPAStoreReference($0), $0.source?.apps ?? []) }) }
    func contains(_ reference: IPAStoreReference) -> Bool { sources.contains { IPAStoreDirectory.canonical($0.url) == reference.id } }
    func source(for reference: IPAStoreReference) -> AltStoreSource? { sources.first { IPAStoreDirectory.canonical($0.url) == reference.id }?.source }
}

struct IPAStoreArtwork: View {
    let source: AltStoreSource?
    var reference: IPAStoreReference? = nil
    var size: CGFloat = 64
    private var icon: URL? { source?.iconURL ?? reference?.suggestion?.iconURL ?? source?.apps.first(where: { $0.iconURL != nil })?.iconURL }
    var body: some View {
        IPARemoteImage(url: icon, pixels: Int(size * 3), fallbackAsset: reference?.suggestion?.bundledIconName, fallbackSymbol: IPAStyle.storeSymbol, fallbackText: reference?.name ?? source?.name, fallbackURLs: [reference?.suggestion?.iconURL, source?.apps.first(where: { $0.iconURL != nil })?.iconURL].compactMap { $0 })
            .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)).accessibilityHidden(true)
    }
}

struct IPALibraryCard: View {
    let reference: IPAStoreReference
    let source: AltStoreSource?
    let subtitle: String
    var allowsAdding = false
    @ScaledMetric(relativeTo: .body) private var height = 100.0
    var body: some View {
        HStack(spacing: 14) {
            NavigationLink { IPAStorePage(reference: reference) } label: {
                HStack(spacing: 14) {
                    IPAStoreArtwork(source: source, reference: reference, size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(reference.name).ipaFont(.headline, weight: .semibold).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                        Text(subtitle).ipaFont(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !allowsAdding { Image(systemName: "chevron.right").ipaFont(.caption, weight: .semibold).foregroundStyle(.tertiary) }
                }.contentShape(Rectangle())
            }.buttonStyle(IPAControlPressStyle(scale: 0.985))
            if allowsAdding { IPAAddLibraryButton(reference: reference).fixedSize(horizontal: true, vertical: false) }
        }.padding(.horizontal, 18).frame(height: height).background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct IPAAddLibraryButton: View {
    let reference: IPAStoreReference
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @EnvironmentObject private var model: SharedModel
    @State private var working = false
    @State private var failure: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var added: Bool { catalog.contains(reference) }
    var body: some View {
        Button {
            working = true
            Task {
                if let error = await catalog.addSource(from: reference.url.absoluteString) { failure = error.ipaDisplayMessage }
                else {
                    UIAccessibility.post(notification: .announcement, argument: "Library added")
                    IPAFeedback.confirmationHaptic()
                }
                working = false
            }
        } label: {
            ZStack {
                if working { ProgressView().transition(IPAMotion.reveal(reduced: reduceMotion)) }
                else { Text(added ? "Added" : "Add").contentTransition(.opacity).transition(IPAMotion.reveal(reduced: reduceMotion)) }
            }.ipaFont(.subheadline, weight: .bold).frame(width: 82, height: 34).background(Color.accentColor.opacity(0.09), in: Capsule())
        }.buttonStyle(IPAControlPressStyle())
            .animation(IPAMotion.state(reduced: reduceMotion), value: working)
            .animation(IPAMotion.state(reduced: reduceMotion), value: added)
            .foregroundStyle(added ? Color.secondary : .accentColor)
            .disabled(working || catalog.contains(reference))
            .accessibilityLabel(catalog.contains(reference) ? "\(reference.name), added" : "Add \(reference.name)")
            .alert("Unable to Add Library", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
    }
}

struct IPASuggestionCards: View {
    var query = ""
    @EnvironmentObject private var discovery: IPADiscovery
    private var suggestions: [IPAStoreSuggestion] { discovery.availableSuggestions.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        LazyVStack(spacing: 16) {
            ForEach(suggestions) { item in
                let source = discovery.sources[item.id]
                let count = source?.apps.count ?? 0
                IPALibraryCard(reference: IPAStoreReference(item), source: source,
                               subtitle: count == 1 ? "1 app" : "\(count) apps", allowsAdding: true)
            }
            if suggestions.isEmpty {
                if discovery.loading { ProgressView("Finding Libraries…").frame(maxWidth: .infinity).padding(.vertical, 32) }
                else { IPAEmptyState(title: "No Libraries Available", subtitle: query.isEmpty ? "Available libraries will appear here." : "Try a different search.", symbol: IPAStyle.storeSymbol) }
            }
        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 24)
    }
}

extension View {
    func ipaTallSheet() -> some View {
        presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

struct IPASuggestionsView: View {
    @State private var adding = false

    var body: some View {
        ScrollView { IPASuggestionCards() }
            .background(IPAStyle.canvas)
            .navigationTitle("Suggestions")
            .navigationBarTitleDisplayMode(.inline)
            .ipaNativePage()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .tint(.primary).accessibilityLabel("Add Store")
                }
            }
            .sheet(isPresented: $adding) { IPAAddStoreSheet() }
    }
}

struct IPAStoreAllAppsView: View {
    let reference: IPAStoreReference
    var fallback: IPAAppEntry? = nil
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @EnvironmentObject private var discovery: IPADiscovery
    @ObservedObject private var libraryIndex = IPALibraryIndex.shared

    private var source: AltStoreSource? { catalog.source(for: reference) ?? discovery.source(for: reference) }

    var body: some View {
        let entries = libraryIndex.entries(reference: reference, source: source)
        if entries.isEmpty, let source, !source.apps.isEmpty {
            ProgressView("Preparing apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("All Apps").navigationBarTitleDisplayMode(.inline).ipaNativePage()
        } else {
            IPACategoryView(category: .init(name: "All Apps", apps: entries.isEmpty ? [fallback].compactMap { $0 } : entries))
                .id(source?.id)
        }
    }
}

struct IPAStorePage: View {
    let reference: IPAStoreReference
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @EnvironmentObject private var discovery: IPADiscovery
    @ScaledMetric(relativeTo: .subheadline) private var metadataHeight = 58.0
    @ObservedObject private var libraryIndex = IPALibraryIndex.shared
    @State private var requested = false
    private var loadingLibrary: Bool {
        !requested || reference.suggestion.map { discovery.loadingIDs.contains($0.id) } == true || catalog.sources.contains { IPAStoreDirectory.canonical($0.url) == reference.id && $0.isLoading }
    }
    private var source: AltStoreSource? { catalog.source(for: reference) ?? discovery.source(for: reference) }
    private var entries: [IPAAppEntry] { libraryIndex.entries(reference: reference, source: source) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 18) {
                    IPAStoreArtwork(source: source, reference: reference, size: 92)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reference.name).ipaFont(.title2, weight: .bold).lineLimit(2).truncationMode(.tail)
                        Text(reference.summary).ipaFont(.subheadline).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
                        IPAAddLibraryButton(reference: reference)
                    }
                }
                Divider()
                HStack(alignment: .center, spacing: 14) {
                    if !entries.isEmpty {
                        fact("APPS", "\(entries.count)")
                        Divider().frame(height: 34)
                    }
                    IPAWebLink(destination: reference.suggestion?.webURL ?? reference.url) {
                        VStack(alignment: .center, spacing: 4) {
                            Text("WEB").ipaFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                            Image(systemName: "globe").ipaFont(.title3)
                            Text("Open").ipaFont(.caption).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: metadataHeight)
                            .background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 13))
                    }
                    IPAWebLink(destination: reference.publisher ?? source?.website ?? reference.url) {
                        VStack(alignment: .center, spacing: 4) {
                            Text("DEVELOPER").ipaFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                            Text(reference.suggestion?.developer ?? reference.publisher?.host ?? source?.website?.host ?? reference.name).ipaFont(.caption).lineLimit(3).truncationMode(.tail).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, minHeight: metadataHeight)
                            .background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 13))
                    }
                }.frame(height: metadataHeight).clipped()
                Divider()
                if reference.suggestion?.marketplaceOnly == true {
                    Label("Marketplace Library", systemImage: "info.circle").ipaFont(.headline, weight: .semibold)
                    Text("This publisher lists marketplace editions. Adding its catalog does not make marketplace-only downloads installable here. Open Web for the publisher’s supported installation options.").ipaFont(.subheadline).foregroundStyle(.secondary)
                }
                Text("About This Library").ipaFont(.title2, weight: .bold)
                Text(reference.suggestion?.editorialDescription ?? source?.description ?? reference.summary)
                    .ipaFont(.body).foregroundStyle(.secondary).textSelection(.enabled)
                if source == nil {
                    if loadingLibrary { ProgressView("Loading apps…").frame(maxWidth: .infinity).padding(.vertical) }
                    else {
                        IPAEmptyState(title: "Library Unavailable", subtitle: "Check Web for the current source address, or try again later. Your added library is kept.", symbol: "wifi.exclamationmark")
                        Button("Try Again") { Task { if let item = catalog.sources.first(where: { IPAStoreDirectory.canonical($0.url) == reference.id }) { await catalog.refreshSource(item) } else { await discovery.reload(reference) } } }.frame(maxWidth: .infinity)
                    }
                } else if entries.isEmpty && source?.apps.isEmpty == false {
                    ProgressView("Preparing apps…").frame(maxWidth: .infinity).padding(.vertical)
                } else if entries.isEmpty {
                    IPAEmptyState(title: "No Apps Yet", subtitle: "This library hasn’t published any apps.", symbol: "square.stack.3d.up")
                } else if let app = entries.first, entries.count == 1 {
                    Text("In This Library").ipaFont(.title2, weight: .bold)
                    IPAAppRow(entry: app)
                } else {
                    IPACategoryShelves(categories: libraryIndex.categories(reference: reference, source: source), title: "In This Library", library: reference)
                }

            }.padding(20).padding(.bottom, 20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.background(IPAStyle.productCanvas).navigationBarTitleDisplayMode(.inline).ipaNativePage()
            .task {
                requested = true
                guard source == nil else { return }
                if let stored = catalog.sources.first(where: { IPAStoreDirectory.canonical($0.url) == reference.id }) { await catalog.refreshSource(stored, onlyStale: true) }
                else { await discovery.reload(reference, onlyStale: true) }
            }
            .refreshable {
                if let stored = catalog.sources.first(where: { IPAStoreDirectory.canonical($0.url) == reference.id }) { await catalog.refreshSource(stored) }
                else { await discovery.reload(reference) }
            }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(title).ipaFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
            Text(value).ipaFont(.title3, weight: .semibold).lineLimit(1)
        }.frame(maxWidth: .infinity).multilineTextAlignment(.center)
    }
}

struct IPAAddStoreSheet: View {
    @EnvironmentObject private var catalog: AltStoreSourcesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var adding = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("https://example.com/apps.json", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Source address")
                if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Add Store").navigationBarTitleDisplayMode(.inline).ipaNativePage()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        adding = true
                        Task {
                            if let error = await catalog.addSource(from: address) { failure = error.ipaDisplayMessage }
                            else { dismiss() }
                            adding = false
                        }
                    } label: { if adding { ProgressView() } else { Text("Add").bold() } }
                    .disabled(adding || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(adding)
    }
}
