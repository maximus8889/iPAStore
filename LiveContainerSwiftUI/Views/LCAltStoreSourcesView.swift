//
//  LCAltStoreSourcesView.swift
//  LiveContainerSwiftUI
//
//  Created by Stephen B on 2025/2/15.
//

import Foundation
import SwiftUI
import UIKit
import CryptoKit

struct AltStoreSourceAppVersion: Identifiable, Hashable {
    let id = UUID()
    let version: String
    let buildVersion: String?
    let releaseDate: Date?
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int64?
    var minOSVersion: String? = nil
    var maxOSVersion: String? = nil
    var sha256: String? = nil
}

struct AltStoreSourceApp: Identifiable, Hashable {
    var id: String { bundleIdentifier + "|" + (latestVersion?.downloadURL.absoluteString ?? "") }
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let tintColor: Color?
    let screenshots: [URL]
    let versions: [AltStoreSourceAppVersion]
    let latestVersion: AltStoreSourceAppVersion?
    let isBeta: Bool
    var category: String? = nil
    var headerURL: URL? = nil
    var requiresJIT: Bool = false
}

extension AltStoreSourceApp {
    func selecting(_ version: AltStoreSourceAppVersion) -> Self {
        Self(name: name, bundleIdentifier: bundleIdentifier, developerName: developerName, subtitle: subtitle, description: description, iconURL: iconURL, tintColor: tintColor, screenshots: screenshots, versions: versions, latestVersion: version, isBeta: isBeta, category: category, headerURL: headerURL, requiresJIT: requiresJIT)
    }
}

struct AltStoreSource: Identifiable, Hashable {
    var id = UUID()
    let name: String
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let headerURL: URL?
    let tintColor: Color?
    let website: URL?
    let apps: [AltStoreSourceApp]
}

private struct AltStoreSourceResponse: Decodable {
    let name: String?
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let headerURL: String?
    let tintColor: String?
    let website: String?
    let apps: [AltStoreSourceAppResponse]?
}

private struct SourceCategory: Decodable {
    let name: String?
    private struct Named: Decodable { let name: String?; let genreName: String? }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { name = text }
        else if let number = try? value.decode(Int.self) { name = String(number) }
        else if let list = try? value.decode([String].self) { name = list.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        else if let object = try? value.decode(Named.self) { name = object.name ?? object.genreName }
        else if let list = try? value.decode([Named].self) { name = list.compactMap { $0.name ?? $0.genreName }.first }
        else { name = nil }
    }
}
private struct SourceByteCount: Decodable {
    let bytes: Int64?
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        let number = (try? value.decode(Int64.self)) ?? (try? value.decode(String.self)).flatMap(Int64.init)
        bytes = number.flatMap { $0 > 0 ? $0 : nil }
    }
}

private struct SourceScreenshots: Decodable {
    let urls: [String]
    private struct Shot: Decodable { let imageURL: String }
    private struct Devices: Decodable { let iphone: SourceScreenshots?; let ipad: SourceScreenshots? }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let strings = try? value.decode([String].self) { urls = strings }
        else if let objects = try? value.decode([Shot].self) { urls = objects.map(\.imageURL) }
        else if let devices = try? value.decode(Devices.self) { urls = devices.iphone?.urls ?? devices.ipad?.urls ?? [] }
        else { urls = [] }
    }
}

private struct AltStoreSourceAppResponse: Decodable {
    let beta: Bool?
    let requiresJIT: Bool?
    let category: SourceCategory?
    let categories: SourceCategory?
    let genre: SourceCategory?
    let genres: SourceCategory?
    let primaryGenreName: SourceCategory?
    let primaryGenreId: SourceCategory?
    let type: SourceCategory?
    let size: SourceByteCount?
    let name: String?
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let version: String?
    let versionDate: String?
    let versionDescription: String?
    let downloadURL: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let screenshotURLs: [String]?
    let screenshots: SourceScreenshots?
    let headerURL: String?
    let minOSVersion: String?
    let maxOSVersion: String?
    let sha256: String?
    let versions: [AltStoreSourceAppVersionResponse]?
    
    enum CodingKeys: String, CodingKey {
        case beta, requiresJIT
        case category
        case categories, genre, genres, primaryGenreName, primaryGenreId, type, size
        case name
        case bundleIdentifier
        case developerName
        case subtitle
        case version
        case versionDate
        case versionDescription
        case downloadURL
        case localizedDescription
        case iconURL
        case tintColor
        case screenshotURLs, screenshots, headerURL, minOSVersion, maxOSVersion, sha256
        case versions
    }
}

private struct AltStoreSourceAppVersionResponse: Decodable {
    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    let minOSVersion: String?
    let maxOSVersion: String?
    let sha256: String?
    
    enum CodingKeys: String, CodingKey {
        case version
        case buildVersion = "buildNumber"
        case date
        case localizedDescription
        case downloadURL
        case size, minOSVersion, maxOSVersion, sha256
    }
}

@MainActor
final class AltStoreSourcesViewModel: ObservableObject {
    struct SourceItem: Identifiable, Hashable {
        let id: URL
        let url: URL
        var source: AltStoreSource?
        var isLoading: Bool
        var error: String?
        var lastCheckedAt: Date?
        
        init(url: URL, isLoading: Bool = false, source: AltStoreSource? = nil, error: String? = nil) {
            self.url = url
            self.id = url
            self.isLoading = isLoading
            self.source = source
            self.error = error
        }
        
        var displayName: String {
            if let source {
                return source.name
            }
            if let host = url.host, !host.isEmpty {
                return host
            }
            return url.absoluteString
        }
        
        var primaryIconURL: URL? {
            if let icon = source?.iconURL {
                return icon
            }
            if let appIcon = source?.apps.first(where: { $0.iconURL != nil })?.iconURL {
                return appIcon
            }
            return nil
        }
    }
    
    @Published private(set) var sources: [SourceItem] = []
    @Published var isRefreshingAll = false
    private let defaultsKey = "LCAltStoreSourceURLs"

    private let cacheDirectoryName = "AltStoreSourceCache"
    private var freshUntil: [URL: Date] = [:]
    private var retryAt: [URL: Date] = [:]
    // Catalog work belongs to this model, not a transient SwiftUI refresh task.
    private var requests: [URL: Task<Void, Never>] = [:]
    private var refreshAllTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var runningStalePass = false
    private var forceAfterCurrentPass = false
    private var lastActivationCheck: Date?
    static let refreshInterval: TimeInterval = 300
    private let defaults: UserDefaults
    private let customCacheDirectory: URL?
    private let loader: @Sendable (URL) async throws -> (AltStoreSource, Data)
    
    init(defaults: UserDefaults = .standard, cacheDirectory: URL? = nil,
         automaticallyRefresh: Bool = true, refreshAllOnLaunch: Bool = false,
         loader: @escaping @Sendable (URL) async throws -> (AltStoreSource, Data) = { try await IPACatalogDownloads.shared.load(from: $0) }) {
        self.defaults = defaults
        self.customCacheDirectory = cacheDirectory
        self.loader = loader
        loadStoredSources()
        guard automaticallyRefresh else { return }
        startupTask = Task {
            await restoreCachedSources()
            await refreshAllSources(onlyStale: !refreshAllOnLaunch)
            startupTask = nil
        }
    }
    
    func addSource(from rawValue: String) async -> String? {
        guard let normalizedURL = normalizeSourceURL(from: rawValue) else {
            return "lc.sources.error.invalidUrl".loc
        }
        
        if sources.contains(where: { AltStoreSourceLoader.canonical($0.url) == AltStoreSourceLoader.canonical(normalizedURL) }) {
            return "lc.sources.error.duplicate".loc
        }
        
        sources.append(SourceItem(url: normalizedURL, isLoading: true))
        persistSources()
        await refreshSource(url: normalizedURL)
        if let item = sources.first(where: { $0.url == normalizedURL }), item.source == nil {
            let error = item.error ?? "This store could not be loaded. Check the address and try again."
            removeSource(item)
            return error
        }
        return nil
    }
    
    func removeSource(_ item: SourceItem) {
        sources.removeAll { $0.id == item.id }
        persistSources()
        removeCache(for: item.url)
    }
    
    func refreshSource(_ item: SourceItem, onlyStale: Bool = false) async {
        if onlyStale, item.source != nil, freshUntil[item.url].map({ $0 > Date() }) == true { return }
        await refreshSource(url: item.url)
    }

    func refreshForActivation() async {
        if let startupTask { await startupTask.value; lastActivationCheck = Date(); return }
        let now = Date()
        guard lastActivationCheck.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastActivationCheck = now
        await refreshAllSources(onlyStale: true)
    }

    func adoptDiscovery(_ snapshot: [URL: (AltStoreSource, Date)]) {
        let byURL = Dictionary(snapshot.map { (AltStoreSourceLoader.canonical($0.key), $0.value) }, uniquingKeysWith: { a, b in a.1 >= b.1 ? a : b })
        var updated = sources, changed = false
        for index in updated.indices {
            let url = updated[index].url
            guard let (source, checked) = byURL[AltStoreSourceLoader.canonical(url)],
                  checked > (updated[index].lastCheckedAt ?? .distantPast) else { continue }
            updated[index].source = source; updated[index].lastCheckedAt = checked; updated[index].error = nil
            updated[index].isLoading = requests[url] != nil
            freshUntil[url] = checked.addingTimeInterval(Self.refreshInterval); retryAt[url] = nil; changed = true
        }
        if changed { sources = updated }
    }
    
    func refreshAllSources(onlyStale: Bool = false) async {
        if let refreshAllTask {
            if !onlyStale && runningStalePass { forceAfterCurrentPass = true }
            await refreshAllTask.value; return
        }
        guard !sources.isEmpty else { return }
        isRefreshingAll = true; runningStalePass = onlyStale; forceAfterCurrentPass = false
        let work = Task { @MainActor in
            repeat {
                if !runningStalePass { forceAfterCurrentPass = false }
                let urls = sources.filter { item in
                    !runningStalePass || ((item.source == nil || freshUntil[item.url].map({ $0 <= Date() }) != false) && retryAt[item.url].map({ $0 <= Date() }) != false)
                }.map(\.url)
                // One unavailable publisher must not hold up every other library.
                await withTaskGroup(of: Void.self) { group in
                    var remaining = urls.makeIterator()
                    for _ in 0..<4 { if let url = remaining.next() { group.addTask { await self.refreshSource(url: url) } } }
                    while await group.next() != nil {
                        if let url = remaining.next() { group.addTask { await self.refreshSource(url: url) } }
                    }
                }
                runningStalePass = false
            } while forceAfterCurrentPass
            isRefreshingAll = false; refreshAllTask = nil
        }
        refreshAllTask = work
        await work.value
    }

    private func refreshSource(url: URL) async {
        if let work = requests[url] { await work.value; return }
        guard sources.contains(where: { $0.url == url }) else { return }
        let work = Task { @MainActor in
            await performRefresh(url: url)
            requests[url] = nil
        }
        requests[url] = work
        await work.value
    }

    private func performRefresh(url: URL) async {
        guard let index = sources.firstIndex(where: { $0.url == url }) else { return }
        let started = Date()
        sources[index].isLoading = true
        sources[index].error = nil
        do {
            let (source, data) = try await loader(url)
            let checked = Date()
            if let file = cacheFileURL(for: url) { await IPACatalogCacheWriter.shared.store(data, at: file, checked: checked) }
            guard let sourceIndex = sources.firstIndex(where: { $0.url == url }) else { return }
            guard (sources[sourceIndex].lastCheckedAt ?? .distantPast) <= checked else {
                sources[sourceIndex].isLoading = false; return
            }
            var item = sources[sourceIndex]
            if item.source?.id != source.id { item.source = source }
            item.isLoading = false; item.error = nil; item.lastCheckedAt = checked
            freshUntil[url] = checked.addingTimeInterval(Self.refreshInterval); retryAt[url] = nil
            sources[sourceIndex] = item
        } catch {
            if let sourceIndex = sources.firstIndex(where: { $0.url == url }) {
                // Cancellation is not a failed library. Cached apps stay usable.
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                let alreadyUpdated = (sources[sourceIndex].lastCheckedAt ?? .distantPast) > started
                sources[sourceIndex].error = cancelled || alreadyUpdated ? nil : AltStoreSourceLoader.refreshMessage(error)
                if !cancelled && !alreadyUpdated { retryAt[url] = Date().addingTimeInterval(AltStoreSourceLoader.retryDelay(error)) }
                sources[sourceIndex].isLoading = false
            }
        }
    }
    
    private func loadStoredSources() {
        let stored = defaults.array(forKey: defaultsKey) as? [String] ?? []
        let urls = stored.compactMap { URL(string: $0) }
        self.sources = urls.map { SourceItem(url: $0, isLoading: true) }
    }

    private func restoreCachedSources() async {
        let files = sources.compactMap { item in cacheFileURL(for: item.url).map { (item.url, $0) } }
        let restored = await Task.detached(priority: .userInitiated) {
            files.compactMap { url, file -> (URL, AltStoreSource, Date)? in
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
                      let data = try? Data(contentsOf: file), let source = try? AltStoreSourceLoader.decode(from: data, baseURL: url) else { return nil }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, source, date <= Date() ? date : .distantPast)
            }
        }.value
        var updated = sources
        for (url, source, checked) in restored {
            // A removed source stays removed; a fresh network result wins.
            if let index = updated.firstIndex(where: { $0.url == url && $0.source == nil }) {
                updated[index].source = source; updated[index].isLoading = false; updated[index].lastCheckedAt = checked
                freshUntil[url] = checked.addingTimeInterval(Self.refreshInterval)
            }
        }
        sources = updated
    }
    
    private func persistSources() {
        let urls = sources.map { $0.url.absoluteString }
        defaults.set(urls, forKey: defaultsKey)
    }
    
    private func normalizeSourceURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return URL(string: AltStoreSourceLoader.canonical(url))
    }

}

private extension AltStoreSourcesViewModel {
    func cacheFileURL(for url: URL) -> URL? {
        guard let directory = ensureCacheDirectory() else { return nil }
        let fileName = cacheFileName(for: url)
        return directory.appendingPathComponent(fileName)
    }
    
    func ensureCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = customCacheDirectory ?? caches.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }
    
    func cacheFileName(for url: URL) -> String {
        AltStoreSourceLoader.cacheFileName(for: url)
    }
    
    func removeCache(for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            // Ignore cache removal errors
        }
    }
}

// Serialize atomic cache writes by validation time: a slow older request cannot
// replace a newer catalog that another screen has already retrieved.
actor IPACatalogCacheWriter {
    static let shared = IPACatalogCacheWriter()
    private var writtenAt: [URL: Date] = [:]
    func store(_ data: Data, at file: URL, checked: Date) {
        guard writtenAt[file].map({ $0 <= checked }) ?? true else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: checked], ofItemAtPath: file.path)
            writtenAt[file] = checked
        } catch { /* Fresh network data can still be used if caching is unavailable. */ }
    }
}

actor IPACatalogDownloads {
    static let shared = IPACatalogDownloads()
    private var pending: [String: Task<(AltStoreSource, Data), Error>] = [:]
    func load(from url: URL) async throws -> (AltStoreSource, Data) {
        let key = AltStoreSourceLoader.canonical(url)
        if let task = pending[key] { return try await task.value }
        let task = Task { try await AltStoreSourceLoader.load(from: url) }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }
}

enum AltStoreSourceLoader {
    static func cacheFileName(for url: URL) -> String {
        SHA256.hash(data: Data(canonical(url).utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased(); parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/" { parts.percentEncodedPath = "/" }
        return parts.url?.absoluteString ?? url.absoluteString
    }

    static func load(from url: URL) async throws -> (AltStoreSource, Data) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw URLError(.unsupportedURL) }
        // Download to a bounded file instead of iterating millions of individual
        // bytes. Some valid source catalogs are larger than the old8MB limit.
        for attempt in 0..<2 {
            do { return try await downloadOnce(from: url) }
            catch {
                if attempt == 0 && isTransient(error) { try await Task.sleep(nanoseconds: 300_000_000); continue }
                throw error
            }
        }
        throw URLError(.badServerResponse)
    }

    static func isTransient(_ error: Error) -> Bool {
        if let code = (error as? URLError)?.code { return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(code) }
        let e = error as NSError
        return e.domain == "iPAStore.DownloadHTTP" && [500, 502, 503, 504, 520, 521, 522, 523, 524].contains(e.code)
    }
    static func retryDelay(_ error: Error) -> TimeInterval {
        let e = error as NSError
        if e.domain == "iPAStore.DownloadHTTP", [404, 410].contains(e.code) { return 3600 }
        if e.domain == "iPAStore.DownloadHTTP", e.code == 429 { return 900 }
        if e.domain == "iPAStore.LibraryFormat" || error is DecodingError { return 900 }
        return 60
    }
    static func refreshMessage(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == "iPAStore.DownloadHTTP" {
            if [404, 410].contains(e.code) { return "The publisher no longer serves this library address (HTTP \(e.code)). Your saved catalog is kept. Check the publisher’s website for a current address." }
            if e.code == 429 { return "The publisher is limiting requests. Your saved catalog is kept; try again later." }
            return "The publisher returned HTTP \(e.code). Your saved catalog is kept. Try again later."
        }
        if error is DecodingError { return "The publisher’s response isn’t a supported app catalog. Your saved catalog is kept. Check the publisher’s website for the current library address." }
        return error.localizedDescription
    }
    private static func downloadOnce(from url: URL) async throws -> (AltStoreSource, Data) {
        let transfer = IPADownloadTransfer(maximumBytes: 32 * 1024 * 1024, requestTimeout: 20, resourceTimeout: 45,
                                           headers: ["Accept": "application/json", "Cache-Control": "no-cache", "User-Agent": "iPAStore/1.0"],
                                           cachePolicy: .reloadIgnoringLocalCacheData) { _ in }
        let file = try await transfer.download(url)
        defer { try? FileManager.default.removeItem(at: file) }
        let finalURL = transfer.resolvedURL ?? url
        guard ["https", "http"].contains(finalURL.scheme?.lowercased() ?? ""), finalURL.user == nil, finalURL.password == nil else { throw URLError(.unsupportedURL) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let prefix = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") {
            throw NSError(domain: "iPAStore.LibraryFormat", code: 1, userInfo: [NSLocalizedDescriptionKey: "The publisher returned a webpage instead of an app catalog. Your saved catalog is kept. Check its website for the current library address."])
        }
        let source = try decode(from: data, baseURL: finalURL)
        return (source, data)
    }
    
    static func decode(from data: Data, baseURL: URL) throws -> AltStoreSource {
        var source = try decodeSource(from: data, baseURL: baseURL)
        // Equal publisher bytes retain one revision across subscriptions/discovery.
        let digest = SHA256.hash(data: data)
        source.id = UUID(uuid: digest.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
        return source
    }
    
    private static func decodeSource(from data: Data, baseURL: URL) throws -> AltStoreSource {
        let decoder = JSONDecoder()
        let dates = SourceDates()
        decoder.dateDecodingStrategy = .custom({ decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = dates.parse(rawValue) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(rawValue)")
        })
        
        let response = try decoder.decode(AltStoreSourceResponse.self, from: data)
        guard let name = response.name else {
            throw NSError(domain: "AltStoreSource", code: 0, userInfo: [NSLocalizedDescriptionKey: "lc.sources.error.malformed".loc])
        }
        let apps = (response.apps ?? []).compactMap { appResponse in
            buildApp(from: appResponse, baseURL: baseURL, fallbackTint: response.tintColor, dates: dates)
        }
        return AltStoreSource(
            name: name,
            identifier: response.identifier,
            subtitle: response.subtitle,
            description: response.description,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            headerURL: url(for: response.headerURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor),
            website: url(for: response.website, baseURL: baseURL),
            apps: apps
        )
    }
    
    private static func buildApp(from response: AltStoreSourceAppResponse, baseURL: URL, fallbackTint: String?, dates: SourceDates) -> AltStoreSourceApp? {
        guard let name = response.name,
              let bundleIdentifier = response.bundleIdentifier else {
            return nil
        }
        
        let versions = buildVersions(from: response, baseURL: baseURL, dates: dates)
        let latest = versions.first ?? buildLegacyVersion(from: response, baseURL: baseURL, dates: dates)
        let declaredCategory = [response.category, response.categories, response.primaryGenreName, response.primaryGenreId, response.genre, response.genres]
            .compactMap { $0?.name?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let host = baseURL.host?.lowercased() ?? ""
        let appTesters = (host == "raw.githubusercontent.com" && baseURL.path.lowercased().hasPrefix("/apptesters-org/apptesters_repo/")) || host == "repository.apptesters.org"
        
        return AltStoreSourceApp(
            name: name,
            bundleIdentifier: bundleIdentifier,
            developerName: response.developerName,
            subtitle: response.subtitle,
            description: response.localizedDescription ?? response.versionDescription,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor ?? fallbackTint),
            screenshots: (response.screenshots?.urls.isEmpty == false ? response.screenshots!.urls : response.screenshotURLs ?? []).compactMap { url(for: $0, baseURL: baseURL) },
            versions: versions,
            latestVersion: latest,
            isBeta: response.beta ?? false,
            category: declaredCategory ?? (appTesters && response.type?.name == "2" ? "Games" : nil),
            headerURL: url(for: response.headerURL, baseURL: baseURL),
            requiresJIT: response.requiresJIT ?? false
        )
    }
    
    private static func buildVersions(from response: AltStoreSourceAppResponse, baseURL: URL, dates: SourceDates) -> [AltStoreSourceAppVersion] {
        guard let versions = response.versions else { return [] }
        return versions.compactMap { version in
            guard let versionString = version.version,
                  let downloadURLString = version.downloadURL,
                  let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
                return nil
            }
            return AltStoreSourceAppVersion(
                version: versionString,
                buildVersion: version.buildVersion,
                releaseDate: dates.parse(version.date),
                localizedDescription: version.localizedDescription,
                downloadURL: downloadURL,
                size: version.size,
                minOSVersion: version.minOSVersion,
                maxOSVersion: version.maxOSVersion,
                sha256: version.sha256
            )
        }
    }
    
    private static func buildLegacyVersion(from response: AltStoreSourceAppResponse, baseURL: URL, dates: SourceDates) -> AltStoreSourceAppVersion? {
        guard let versionString = response.version,
              let downloadURLString = response.downloadURL,
              let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
            return nil
        }
        return AltStoreSourceAppVersion(
            version: versionString,
            buildVersion: nil,
            releaseDate: dates.parse(response.versionDate),
            localizedDescription: response.versionDescription,
            downloadURL: downloadURL,
            size: response.size?.bytes,
            minOSVersion: response.minOSVersion,
            maxOSVersion: response.maxOSVersion,
            sha256: response.sha256
        )
    }
    
    // Each decode owns its formatters: no per-version construction and no
    // shared mutable formatter races between concurrently loaded libraries.
    private final class SourceDates {
        private let iso = ISO8601DateFormatter()
        private let short = DateFormatter()
        init() { short.dateFormat = "yyyy-MM-dd" }
        func parse(_ value: String?) -> Date? {
            guard let value else { return nil }
            return iso.date(from: value) ?? short.date(from: value)
        }
    }
    
    private static func url(for string: String?, baseURL: URL) -> URL? {
        guard let string = string, !string.isEmpty else { return nil }
        guard let resolved = URL(string: string, relativeTo: baseURL)?.absoluteURL,
              ["https", "http"].contains(resolved.scheme?.lowercased() ?? ""),
              resolved.host != nil, resolved.user == nil, resolved.password == nil else { return nil }
        return resolved
    }
    
    private static func color(from hex: String?) -> Color? {
        guard let hex = hex else { return nil }
        return Color(hexString: hex)
    }
}

private extension Color {
    init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")
        
        if cleaned.count == 3 {
            var expanded = ""
            for character in cleaned {
                expanded.append(character)
                expanded.append(character)
            }
            cleaned = expanded
        }
        
        if cleaned.count == 6 {
            cleaned.append("FF")
        }
        
        guard cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            return nil
        }
        
        let red = Double((value & 0xFF00_0000) >> 24) / 255.0
        let green = Double((value & 0x00FF_0000) >> 16) / 255.0
        let blue = Double((value & 0x0000_FF00) >> 8) / 255.0
        let alpha = Double(value & 0x0000_00FF) / 255.0
        
        self = Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct LCSourcesView: View {
    @StateObject private var viewModel = AltStoreSourcesViewModel()
    @State private var errorMessage: String?
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @ObservedObject public var searchContext: SearchContext = SearchContext()
    @State private var expandedSources: Set<URL> = []
    @State private var isManagingSources = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var isViewAppeared = false
    
    var body: some View {
        NavigationView {
            Group {
                if viewModel.sources.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("lc.sources.empty".loc)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(viewModel.sources, id: \.id) { item in
                                let apps = filteredApps(for: item)
                                AltStoreSourceSectionView(
                                    item: item,
                                    filteredApps: apps,
                                    isFiltering: isFiltering,
                                    isExpanded: expandedSources.contains(item.id),
                                    onRefresh: { Task { await viewModel.refreshSource(item) } },
                                    onInstall: install(app:),
                                    onRemove: { sourcePendingRemoval = item },
                                    toggleExpanded: { toggleExpansion(for: item.id) }
                                )
                                .padding(.horizontal)
                                .animation(.easeInOut, value: apps.count)
                            }
                            
                            if totalFilteredAppCount == 0 {
                                VStack(spacing: 8) {
                                    Text("lc.sources.section.noApps".loc)
                                        .foregroundStyle(.gray)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 160, alignment: .center)
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("lc.tabView.sources".loc)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.isRefreshingAll {
                        ProgressView()
                    } else {
                        Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                            Task { await viewModel.refreshAllSources() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.sources.addSource".loc, systemImage: "plus") {
                        isManagingSources = true
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: Binding<Bool>(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("lc.sources.removeConfirmation.title".loc, isPresented: Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } })
        ) {
            Button("lc.common.remove".loc, role: .destructive) {
                if let sourcePendingRemoval {
                    viewModel.removeSource(sourcePendingRemoval)
                }
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: {
            if let name = sourcePendingRemoval?.displayName {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(name))
            } else {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(""))
            }
        }
        .sheet(isPresented: $isManagingSources) {
            if #available(iOS 16.0, *) {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
                .presentationDetents([.large])
            } else {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
            }
        }
        .searchable(text: $searchContext.query, placement: .navigationBarDrawer(displayMode: .always))

        .onAppear {
            expandedSources = []
            if !isViewAppeared {
                guard sharedModel.selectedTab == .sources, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: viewModel.sources) { newSources in
            let newSet = Set(newSources.map { $0.id })
            expandedSources = expandedSources.intersection(newSet)
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .sources, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }
    
    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var totalFilteredAppCount: Int {
        viewModel.sources.reduce(0) { partialResult, item in
            partialResult + filteredApps(for: item).count
        }
    }
    
    private func filteredApps(for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        guard let source = item.source else { return [] }
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return source.apps
        }
        return source.apps.filter { app in
            let lower = query.lowercased()
            if app.name.lowercased().contains(lower) {
                return true
            }
            if app.bundleIdentifier.lowercased().contains(lower) {
                return true
            }
            if let developer = app.developerName?.lowercased(), developer.contains(lower) {
                return true
            }
            if let subtitle = app.subtitle?.lowercased(), subtitle.contains(lower) {
                return true
            }
            return false
        }
    }
    
    @MainActor
    private func handleAddSource(_ rawValue: String) async -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let error = await viewModel.addSource(from: trimmed)
        if let error {
            errorMessage = error
            return false
        }
        return true
    }
    
    @MainActor
    private func install(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": downloadURL])
        }


    }
    
    private func toggleExpansion(for id: URL) {
        withAnimation(.easeInOut) {
            if expandedSources.contains(id) {
                expandedSources.remove(id)
            } else {
                expandedSources.insert(id)
            }
        }
    }
    
    func handleURL(url : URL) {
        if url.host == "source" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var sourceUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        sourceUrl = installUrl1
                    }
                }
                if let sourceUrl {
                    DataManager.shared.model.selectedTab = .sources
                    Task { await handleAddSource(sourceUrl) }
                }
            }
        }
    }
}

struct ManageSourcesSheet: View {
    @ObservedObject var viewModel: AltStoreSourcesViewModel
    @Binding var isPresented: Bool
    let onAdd: (String) async -> Bool
    
    @State private var manualSourceValue = ""
    @State private var isAddingManual = false
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @FocusState private var isManualFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    if viewModel.sources.isEmpty {
                        Text("lc.sources.empty".loc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { item in
                            HStack(alignment: .top, spacing: 12) {
                                SourceIconView(url: resolvedIconURL(for: item))
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .bold()
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sourcePendingRemoval = item
                                } label: {
                                    Label("lc.sources.removeSource".loc, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("lc.sources.manage.current".loc)
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://example.com/source.json", text: $manualSourceValue)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($isManualFieldFocused)
                        
                        Button {
                            attemptManualAdd()
                        } label: {
                            if isAddingManual {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("lc.sources.addSource".loc)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingManual)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("lc.sources.manage.manual".loc)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("lc.sources.addSource".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) {
                        isPresented = false
                    }
                }
            }
        }
        .confirmationDialog(
            "lc.sources.removeConfirmation.title".loc,
            isPresented: Binding<Bool>(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            presenting: sourcePendingRemoval
        ) { item in
            Button("lc.common.remove".loc, role: .destructive) {
                viewModel.removeSource(item)
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { item in
            Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(item.displayName))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func resolvedIconURL(for item: AltStoreSourcesViewModel.SourceItem) -> URL? {
        if let icon = item.primaryIconURL {
            return icon
        }
        if let existing = viewModel.sources.first(where: { $0.url == item.url }) {
            if let icon = existing.primaryIconURL {
                return icon
            }
        }
        return nil
    }
    
    private func attemptManualAdd() {
        let trimmed = manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAddingManual else { return }
        isAddingManual = true
        Task {
            let success = await onAdd(trimmed)
            if success {
                manualSourceValue = ""
                isManualFieldFocused = false
            }
            isAddingManual = false
        }
    }
}

private struct AltStoreSourceSectionView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let filteredApps: [AltStoreSourceApp]
    let isFiltering: Bool
    let isExpanded: Bool
    let onRefresh: () -> Void
    let onInstall: (AltStoreSourceApp) -> Void
    let onRemove: () -> Void
    let toggleExpanded: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                        SourceIconView(url: item.primaryIconURL)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.source?.name ?? item.displayName)
                            .font(.system(.title2).bold())
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if item.isLoading {
                    ProgressView()
                } else {
                    Menu {
                        Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                        Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if item.source == nil, let host = item.url.host {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if let error = item.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text("lc.sources.section.error".loc)
                        .font(.subheadline)
                        .bold()
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("lc.sources.refresh".loc, action: onRefresh)
                        .font(.footnote)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(uiColor: UIColor.secondarySystemBackground))
                )
            } else if let source = item.source, isExpanded || isFiltering {
                VStack(spacing: 12) {
                    ForEach(filteredApps[0..<min(50, filteredApps.count)]) { app in
                        LCSourceAppBanner(app: app, source: source, installAction: onInstall)
                    }
                    if filteredApps.isEmpty {
                        if source.apps.isEmpty || isFiltering {
                            Text("lc.sources.section.noApps".loc)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if filteredApps.count > 50 {
                        Text("lc.sources.section.tooManyApps".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if item.isLoading {
                ProgressView("lc.sources.loading".loc)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let installAction: (AltStoreSourceApp) -> Void
    
    @AppStorage("dynamicColors") private var dynamicColors = true
    @Environment(\.colorScheme) var colorScheme
    
    private var primaryColor: Color {
        guard dynamicColors else { return Color("FontColor") }
        return app.tintColor ?? source.tintColor ?? Color("FontColor")
    }
    
    private var textColor: Color {
        _ = colorScheme == .dark // trigger refresh
        let color = dynamicColors ? primaryColor : Color("FontColor")
        return color.readableTextColor()
    }
    
    private var backgroundColor: Color {
        dynamicColors ? primaryColor.opacity(0.5) : Color("AppBannerBG")
    }
    
    private var metadataText: String {
        guard let latest = app.latestVersion else {
            return app.bundleIdentifier
        }
        if let build = latest.buildVersion, !build.isEmpty {
            return "\(latest.version) (\(build)) • \(app.bundleIdentifier)"
        }
        return "\(latest.version) • \(app.bundleIdentifier)"
    }
    
    private var subtitleText: String {
        if let subtitle = app.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if let developer = app.developerName, !developer.isEmpty {
            return developer
        }
        return ""
    }
    
    var body: some View {
        HStack {
            HStack(alignment: .center, spacing: 12) {
                SourceIconView(url: app.iconURL)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 16)).bold()
                        if app.isBeta {
                            Text("lc.sources.badge.beta".loc.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                    Text(metadataText)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                }
            }
            .allowsHitTesting(false)
            Spacer()
            Button {
                installAction(app)
            } label: {
                Text("lc.common.install".loc)
                    .bold()
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(height: 32)
                    .minimumScaleFactor(0.1)
            }
            .buttonStyle(BasicButtonStyle())
            .padding()
            .frame(idealWidth: 70)
            .frame(height: 32)
            .fixedSize()
            .background(
                Capsule().fill(dynamicColors ? primaryColor : Color("FontColor"))
            )
            .clipShape(Capsule())
        }
        .padding()
        .frame(height: 88)
        .background {
            RoundedRectangle(cornerSize: CGSize(width: 22, height: 22))
                .fill(backgroundColor)
        }
    }
}

private struct SourceIconView: View {
    let url: URL?
    
    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholder
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }
    
    private var placeholder: some View {
        Image("DefaultIcon")
            .resizable()
            .scaledToFill()
    }
}
