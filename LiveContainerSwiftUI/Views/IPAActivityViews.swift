import SwiftUI

struct IPAHistoryRow: View {
    let record: IPAActivityRecord
    @EnvironmentObject private var index: IPAAllAppsIndex
    private var entry: IPAAppEntry? {
        guard let candidate = index.entry(identifier: record.identifier) else { return nil }
        // Keep the actual publisher when a history entry came from a specific library.
        if let url = record.libraryURL,
           let variant = candidate.variants.first(where: { $0.store.id == IPAStoreDirectory.canonical(url) }) { return .init(id: candidate.id, variants: [variant]) }
        return candidate
    }
    var body: some View {
        Group {
            if let entry { IPAAppRow(entry: entry) }
            else {
                NavigationLink { IPAHistoryDetail(record: record) } label: {
                    HStack(spacing: 12) {
                        IPAArtwork(url: record.iconURL, size: 60, identifier: record.identifier)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).ipaFont(.headline, weight: .semibold).lineLimit(1)
                            Text(record.libraryName ?? "Imported from Files").ipaFont(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").ipaFont(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

struct IPAHistoryList: View {
    var downloaded = false
    @ObservedObject private var history = IPAActivityHistory.shared
    @State private var query = ""
    @State private var order = "recent"
    @State private var searching = false
    private var records: [IPAActivityRecord] {
        let all = (downloaded ? history.downloads : history.recent).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.libraryName ?? "").localizedCaseInsensitiveContains(query)
        }
        return order == "name" ? all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : order == "oldest" ? all.sorted { $0.date < $1.date } : all
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(records) { record in
                    IPAHistoryRow(record: record).contextMenu {
                        Button("Remove from History", systemImage: "minus.circle", role: .destructive) { history.remove(record, downloaded: downloaded) }
                    }
                    Divider().padding(.leading, 72)
                }
            }.padding(.horizontal, 20).padding(.bottom, 24).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .overlay {
            if records.isEmpty {
                IPACollectionEmptyState(
                    symbol: query.isEmpty ? (downloaded ? "arrow.down.circle" : "clock") : "magnifyingglass",
                    message: query.isEmpty ? (downloaded ? "Your downloaded apps appear here." : "Your recent apps appear here.") : "No matching apps."
                ) {}
                .allowsHitTesting(false)
            }
        }
        .background(IPAStyle.canvas).navigationTitle(downloaded ? "Downloaded Apps" : "Recent Apps").navigationBarTitleDisplayMode(.inline).ipaNativePage()
            .modifier(IPACollectionSearch(query: $query, presented: $searching))
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Menu { Button("Search", systemImage: "magnifyingglass") { searching = true }; Divider(); Picker("Sort", selection: $order) { Text("Most Recent").tag("recent"); Text("Oldest First").tag("oldest"); Text("Name").tag("name") }.pickerStyle(.inline).labelsHidden() } label: { Image(systemName: "line.3.horizontal.decrease") }.accessibilityLabel("Sort history")
            } }
    }
}

private struct IPAHistoryDetail: View {
    let record: IPAActivityRecord
    @EnvironmentObject private var model: SharedModel
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    private var installed: Bool { model.apps.contains { $0.appInfo.bundleIdentifier() == record.identifier } || installer.independentApps.contains { $0.identifier == record.identifier } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    IPAArtwork(url: record.iconURL, size: 100, identifier: record.identifier)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.name).ipaFont(.title2, weight: .bold)
                        if installed { Button("Open") {
                            #if !IPASTORE_PREVIEW
                            Task { await installer.open(record.identifier) }
                            #endif
                        }.buttonStyle(IPAPillStyle(prominent: true)) }
                    }
                }
                if let version = record.version { LabeledContent("Recorded Version", value: version) }
                Text("This app’s current library listing is unavailable. Refresh its library to see current download options.").foregroundStyle(.secondary)
                if let url = record.libraryURL { NavigationLink { IPAStorePage(reference: .init(url: url, name: record.libraryName ?? "App Library", summary: "An independent app library.", publisher: nil)) } label: { Label("Open Library", systemImage: IPAStyle.storeSymbol) } }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.background(IPAStyle.canvas).navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}

struct IPARecentShelf: View {
    @ObservedObject private var history = IPAActivityHistory.shared
    @ScaledMetric(relativeTo: .body) private var rowHeight = 88.0
    private var pages: [[IPAActivityRecord]] {
        IPACatalogPresentation.shelfPages(history.recent)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink { IPAHistoryList() } label: {
                HStack(spacing: 6) { Text("Recent").ipaFont(.title2, weight: .medium); Image(systemName: "chevron.right").ipaFont(.subheadline, weight: .semibold).foregroundStyle(.tertiary) }.foregroundStyle(.primary)
            }.buttonStyle(.plain)
            IPAAppShelfPages(pages: pages, title: "Recent", rowHeight: rowHeight) { record in
                IPAHistoryRow(record: record)
            }
        }
    }
}

// A stable, shared search field. The collection stays mounted while the Sort
// menu reveals it, preserving scroll position and avoiding navigation rebuilds.
struct IPACollectionSearch: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var query: String
    @Binding var presented: Bool
    var prompt = "Search Apps"
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if presented { IPACollectionSearchField(query: $query, presented: $presented, prompt: prompt).transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)) }
        }.animation(reduceMotion ? nil : IPAMotion.state(reduced: false), value: presented).scrollDismissesKeyboard(.interactively)
    }
}
private struct IPACollectionSearchField: View {
    @Binding var query: String
    @Binding var presented: Bool
    @State private var editing = false
    let prompt: String
    var body: some View {
        HStack(spacing: 6) {
            IPACatalogSearchField(text: $query, editing: $editing, prompt: prompt, autofocus: true)
                .frame(height: 52)
            if editing {
                IPACloseSearchButton(label: "Dismiss keyboard") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            } else {
                IPACloseSearchButton {
                    query = ""
                    presented = false
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 4).frame(maxWidth: 760).frame(maxWidth: .infinity)
            .background(.bar)
    }
}

struct IPACollectionSortSheet<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String

    var body: some View {
        Form {
            Picker("Sort", selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct IPAArrangeCollectionButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "line.3.horizontal")
                .ipaFont(.subheadline, weight: .semibold)
                .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

enum IPAStoreSort: String, CaseIterable {
    case defaultOrder = "default"
    case alphabetical
    case reverseAlphabetical
    case dateAdded
    case custom

    var title: String {
        switch self {
        case .defaultOrder: "lc.common.default".loc
        case .alphabetical: "lc.appList.sort.alphabetical".loc
        case .reverseAlphabetical: "lc.appList.sort.reverseAlphabetical".loc
        case .dateAdded: "Date Added"
        case .custom: "lc.appList.sort.custom".loc
        }
    }

    func ordered(_ sources: [AltStoreSourcesViewModel.SourceItem], savedOrder: String) -> [AltStoreSourcesViewModel.SourceItem] {
        switch self {
        case .defaultOrder: return sources
        case .alphabetical, .reverseAlphabetical:
            let direction: ComparisonResult = self == .alphabetical ? .orderedAscending : .orderedDescending
            return sources.sorted {
                IPAStoreDirectory.title(for: $0).localizedStandardCompare(IPAStoreDirectory.title(for: $1)) == direction
            }
        case .dateAdded:
            return Array(sources.reversed())
        case .custom:
            let ids = (try? JSONDecoder().decode([String].self, from: Data(savedOrder.utf8))) ?? []
            let positions = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            return sources.map { (positions[IPAStoreDirectory.canonical($0.url)] ?? Int.max, $0) }
                .sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}

struct IPAArrangeLibraries: View {
    let items: [AltStoreSourcesViewModel.SourceItem]
    let onReorder: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [AltStoreSourcesViewModel.SourceItem] = []
    var body: some View {
        NavigationStack {
            List {
                ForEach(ordered) { item in
                    HStack(spacing: 12) { IPAStoreArtwork(source: item.source, reference: IPAStoreReference(item), size: 40); Text(IPAStoreDirectory.title(for: item)).lineLimit(1) }
                }.onMove { from, to in
                    let previous = ordered.map(\.id)
                    ordered.move(fromOffsets: from, toOffset: to)
                    guard ordered.map(\.id) != previous else { return }
                    onReorder(ordered.map { IPAStoreDirectory.canonical($0.url) })
                }
            }
                .listStyle(.plain).scrollContentBackground(.hidden).background(IPAStyle.canvas)
                .environment(\.editMode, .constant(.active))
                .navigationTitle("Arrange Stores").navigationBarTitleDisplayMode(.inline).ipaNativePage()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear { ordered = items }
        }.ipaTallSheet().modifier(IPATheme())
    }
}

struct IPACloseSearchButton: View {
    var label: LocalizedStringKey = "Close search"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44).background(IPAStyle.card, in: Circle())
        }.accessibilityLabel(label)
    }
}
