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
                Menu { Button("Search", systemImage: "magnifyingglass") { searching = true }; Divider(); Picker("Sort", selection: $order) { Text("Most Recent").tag("recent"); Text("Oldest First").tag("oldest"); Text("Name").tag("name") }.pickerStyle(.inline).labelsHidden() } label: { IPACollectionControlIcon(symbol: "line.3.horizontal.decrease") }.accessibilityLabel("Sort history")
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

// Native collection pages put the filter below the navigation bar. Tab roots
// insert the same field directly beneath their own headings.
struct IPACollectionSearch: ViewModifier {
    @Binding var query: String
    @Binding var presented: Bool
    var prompt = "Search Apps"
    var closeButtonCenter: CGFloat?

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if presented {
                GeometryReader { geometry in
                    let trailing = closeButtonCenter.map { geometry.frame(in: .global).maxX - $0 - 22 } ?? 16
                    IPACollectionSearchField(query: $query, presented: $presented, prompt: prompt)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, alignment: closeButtonCenter == nil ? .center : .trailing)
                        .padding(.leading, 8)
                        .padding(.trailing, max(0, trailing))
                }.frame(height: 52).padding(.bottom, 10)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

struct IPACollectionSearchField: View {
    @Binding var query: String
    @Binding var presented: Bool
    var prompt = "Search Apps"
    var belowTabHeading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false

    var body: some View {
        Group {
            if presented {
                HStack(spacing: 6) {
                    IPACatalogSearchField(text: $query, editing: $editing, prompt: prompt, autofocus: true)
                        .frame(height: 52)
                    IPACloseSearchButton(size: belowTabHeading ? IPAStyle.tabCollectionButtonSize : 44) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        query = ""
                        presented = false
                    }
                }
                .padding(.leading, belowTabHeading ? -12 : 0)
                .padding(.top, belowTabHeading ? 8 : 0)
                .transition(reduceMotion ? .opacity : .offset(y: -5).combined(with: .opacity))
            }
        }.animation(IPAMotion.state(reduced: reduceMotion), value: presented)
    }
}


struct IPACollectionSortSheet<Option: Hashable, Arrangement: View>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    @ViewBuilder let arrangement: () -> Arrangement

    var body: some View {
        Form {
            Section {
                Picker("Sort", selection: $selection) {
                    ForEach(options, id: \.self) { Text(title($0)).tag($0) }
                }.pickerStyle(.inline).labelsHidden()
            }
            arrangement()
        }
        .environment(\.editMode, .constant(.active))
        .presentationDetents([.medium])
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
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

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        IPAStoreArtwork(source: item.source, reference: IPAStoreReference(item), size: 40)
                        Text(IPAStoreDirectory.title(for: item)).lineLimit(1)
                    }
                    .moveDisabled(items.count < 2)
                    .listRowBackground(Color.clear)
                }
                .onMove { offsets, destination in
                    var reordered = items
                    reordered.move(fromOffsets: offsets, toOffset: destination)
                    guard reordered.map(\.id) != items.map(\.id) else { return }
                    onReorder(reordered.map { IPAStoreDirectory.canonical($0.url) })
                }
            }
        }
    }
}

struct IPACloseSearchButton: View {
    var label: LocalizedStringKey = "Close search"
    var size: CGFloat = 44
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(scheme == .dark ? IPAStyle.card : Color(white: 0.34), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
