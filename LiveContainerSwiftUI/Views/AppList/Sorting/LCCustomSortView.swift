//
//  LCCustomSortView.swift
//  LiveContainerSwiftUI
//
//  Created by boa-z on 2025/6/21.
//
import SwiftUI

struct LCCustomSortRows: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var manager = LCAppSortManager.shared
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    var body: some View {
        let visibleSort = manager.customSortOrder.isEmpty ? manager.appSortType : .custom
        let hiddenSort = sharedModel.isHiddenAppUnlocked ? visibleSort : .custom
        let apps = manager.getSortedApps(sharedModel.apps, sortType: visibleSort, customSortOrder: manager.customSortOrder)
        let hiddenApps = manager.getSortedApps(sharedModel.hiddenApps, sortType: hiddenSort, customSortOrder: manager.customSortOrder)
        if !apps.isEmpty {
            Section { appRows(apps) { save(visible: $0, hidden: hiddenApps) } }
        }
        if sharedModel.isHiddenAppUnlocked && !hiddenApps.isEmpty {
            Section("lc.appList.hiddenApps".loc) { appRows(hiddenApps) { save(visible: apps, hidden: $0) } }
        }
    }

    private func appRows(_ apps: [LCAppModel], onReorder: @escaping ([LCAppModel]) -> Void) -> some View {
        ForEach(apps, id: \.self) { app in
            HStack {
                IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appInfo.displayName())
                        .ipaFont(.headline, weight: .semibold).lineLimit(1)
                    Text("Version \(app.appInfo.version() ?? "?")")
                        .ipaFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(app.uiSelectedContainer?.name ?? "lc.appBanner.noDataFolder".loc)
                        .ipaFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .moveDisabled(apps.count < 2)
        }
        .onMove { source, destination in
            var reordered = apps
            reordered.move(fromOffsets: source, toOffset: destination)
            if reordered != apps { onReorder(reordered) }
        }
    }

    private func save(visible: [LCAppModel], hidden: [LCAppModel]) {
        manager.customSortOrder = (visible + hidden).compactMap { manager.getUniqueIdentifier(for: $0) }
        manager.appSortType = .custom
    }
}
