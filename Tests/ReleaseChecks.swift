import Foundation

@MainActor enum ReleaseChecks {
    private static func checkLibraryRefreshes() async throws {
        let suite = "iPAStore.RefreshChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: cache) }
        let urls = [URL(string: "https://example.org/one.json")!, URL(string: "https://example.org/two.json")!]
        defaults.set(urls.map(\.absoluteString), forKey: "LCAltStoreSourceURLs")
        let fixture = RefreshFixture116()
        let model = AltStoreSourcesViewModel(defaults: defaults, cacheDirectory: cache, automaticallyRefresh: false,
                                             loader: { try await fixture.load($0) })
        let caller = Task { await model.refreshAllSources() }
        while await fixture.count == 0 { await Task.yield() }
        caller.cancel()
        await caller.value
        precondition(model.sources.allSatisfy { $0.source != nil && $0.error == nil && !$0.isLoading }, "Canceling the presenting page must not cancel library-owned refreshes")
        precondition(!model.isRefreshingAll)
        var count = await fixture.count
        precondition(count == 2)
        await model.refreshAllSources(onlyStale: true)
        count = await fixture.count
        precondition(count == 2, "Fresh catalogs do not refetch on reopening")
        let first = Task { await model.refreshAllSources() }
        let duplicate = Task { await model.refreshAllSources() }
        await first.value; await duplicate.value
        count = await fixture.count
        precondition(count == 4, "Concurrent refresh gestures share one update per library")
        await fixture.setMode(1)
        await model.refreshAllSources()
        precondition(model.sources.allSatisfy { $0.source?.apps.count == 1 && $0.error != nil && !$0.isLoading }, "A real network error must retain cached apps and report a reason")
        await fixture.setMode(2)
        await model.refreshAllSources()
        precondition(model.sources.allSatisfy { $0.source != nil && $0.error == nil && !$0.isLoading }, "Cancellation must not become an unavailable-library error")
        await fixture.setMode(0)
        let retry = Task { await model.refreshSource(model.sources[0]) }
        await Task.yield()
        model.removeSource(model.sources[0])
        await retry.value
        precondition(model.sources.count == 1, "An in-flight refresh must not resurrect a removed library")
        await model.refreshAllSources()
        precondition(model.sources[0].error == nil && model.sources[0].source != nil)
        print("Library refresh checks passed: view cancellation, request coalescing, fresh cache, offline retention, cancellation classification, removal and recovery")
    }

    private static func checkCatalogUpdates119() async throws {
        let suite = "iPAStore.UpdateChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: cache) }
        let known = IPAStoreDirectory.suggestions.first!
        let fixture = UpdateFixture119()
        defaults.set([known.url.absoluteString], forKey: "LCAltStoreSourceURLs")
        let catalog = AltStoreSourcesViewModel(defaults: defaults, cacheDirectory: cache, automaticallyRefresh: false, loader: { try await fixture.load($0) })
        let discovery = IPADiscovery(suggestions: [known], cacheDirectory: cache, loader: { try await fixture.load($0) })
        await catalog.refreshAllSources(); await discovery.load(force: true)
        let old = catalog.sources[0].source!
        await fixture.setGeneration(2)
        await catalog.refreshAllSources()
        discovery.adoptCatalog(catalog.sources)
        precondition(discovery.sources[known.id]?.apps.first?.latestVersion?.version == "2", "A subscription refresh must update the Today/suggestions copy")
        let graph = IPACatalogPresentation.libraries(subscribed: catalog.sources, discovered: [known.id: old])
        let rows = IPACatalogPresentation.entries(graph.map { ($0.0, $0.1?.apps ?? []) })
        precondition(!rows.contains { $0.id == "org.example.removed" }, "Old discovery caches cannot resurrect apps removed by their publisher")
        precondition(rows.first { $0.id == "org.example.updated" }?.variants.count == 1, "One library must not retain two releases from conflicting caches")
        precondition(rows.contains { $0.id == "org.example.new" }, "New apps appear after refresh")
        await fixture.setGeneration(3)
        await discovery.reload(IPAStoreReference(known))
        catalog.adoptDiscovery(discovery.checkedSnapshot(discovery.sources))
        precondition(catalog.sources[0].source?.apps.first?.latestVersion?.version == "3", "A discovery refresh must update the subscribed library page")
        let file = cache.appendingPathComponent(AltStoreSourceLoader.cacheFileName(for: known.url))
        let persisted = try AltStoreSourceLoader.decode(from: Data(contentsOf: file), baseURL: known.url)
        precondition(persisted.apps.first?.latestVersion?.version == "3", "Both catalog paths persist to the same current cache")
        let same = try AltStoreSourceLoader.decode(from: Data(contentsOf: file), baseURL: known.url)
        precondition(same.id == persisted.id && old.id != same.id, "Only changed publisher bytes change the source revision")
        let index = IPAAllAppsIndex()
        index.rebuild(subscribed: catalog.sources, discovered: [known.id: old])
        let indexDeadline = Date().addingTimeInterval(3)
        while index.revision == 0 && Date() < indexDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(index.entry(identifier: "org.example.updated")?.app.latestVersion?.version == "3")
        let matches = await index.search("New App")
        precondition(matches.count == 1 && matches[0].id == "org.example.new", "Prepared Search uses updated publisher apps")
        await fixture.setFailure(true)
        let beforeRestore = await fixture.count
        let restored = AltStoreSourcesViewModel(defaults: defaults, cacheDirectory: cache, loader: { try await fixture.load($0) })
        let deadline = Date().addingTimeInterval(3)
        while restored.sources[0].source == nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        await restored.refreshAllSources(onlyStale: true)
        let afterRestore = await fixture.count
        precondition(restored.sources[0].source?.apps.first?.latestVersion?.version == "3" && afterRestore == beforeRestore, "Fresh subscription startup must reuse the saved catalog without a forced network request")
        await restored.refreshAllSources()
        precondition(restored.sources[0].source?.apps.first?.latestVersion?.version == "3" && restored.sources[0].error != nil, "Offline startup retains the newest saved catalog and reports the real failure")
        await fixture.setFailure(false)
        let orphan = cache.appendingPathComponent("write-order.json")
        let now = Date()
        await IPACatalogCacheWriter.shared.store(Data("new".utf8), at: orphan, checked: now)
        await IPACatalogCacheWriter.shared.store(Data("old".utf8), at: orphan, checked: now.addingTimeInterval(-60))
        let orderedBytes = try Data(contentsOf: orphan)
        precondition(orderedBytes == Data("new".utf8), "A delayed older completion cannot overwrite a newer cache")
        let fail404 = NSError(domain: "iPAStore.DownloadHTTP", code: 404)
        precondition(!AltStoreSourceLoader.isTransient(fail404) && AltStoreSourceLoader.refreshMessage(fail404).contains("no longer serves"), "A removed publisher address must not be described as a temporary retry problem")

        let slow = URL(string: "https://example.org/slow.json")!
        defaults.set([slow.absoluteString, known.url.absoluteString], forKey: "LCAltStoreSourceURLs")
        let mixed = AltStoreSourcesViewModel(defaults: defaults, cacheDirectory: cache.appendingPathComponent("mixed"), automaticallyRefresh: false, loader: { url in
            if url == slow { try await Task.sleep(nanoseconds: 500_000_000) }
            return try await fixture.load(url)
        })
        var fresh = AltStoreSourcesViewModel.SourceItem(url: known.url, source: same)
        fresh.lastCheckedAt = Date()
        mixed.adoptDiscovery([known.url: (same, fresh.lastCheckedAt!)])
        let stalePass = Task { await mixed.refreshAllSources(onlyStale: true) }
        while !mixed.isRefreshingAll { await Task.yield() }
        let previous = await fixture.count
        await mixed.refreshAllSources()
        await stalePass.value
        let after = await fixture.count
        precondition(after >= previous + 3, "Manual refresh queued during a stale-only pass must revalidate previously skipped fresh libraries")
        let parallel = AltStoreSourcesViewModel(defaults: defaults, cacheDirectory: cache.appendingPathComponent("parallel"), automaticallyRefresh: false, loader: { url in
            if url == slow { try await Task.sleep(nanoseconds: 500_000_000) }
            return try await fixture.load(url)
        })
        let batch = Task { await parallel.refreshAllSources() }
        while parallel.sources[1].source == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(parallel.sources[0].isLoading && parallel.sources[0].source == nil, "A slow first publisher must not block another library's update")
        await batch.value
        let isolated = IPADiscovery(suggestions: [known], cacheDirectory: cache.appendingPathComponent("cancel"), loader: { try await fixture.load($0) })
        let caller = Task { await isolated.load(force: true) }
        while !isolated.loading { await Task.yield() }
        caller.cancel(); await caller.value
        precondition(!isolated.loading && isolated.sources[known.id] != nil && isolated.failures.isEmpty, "Discovery refreshes survive cancellation of the presenting screen")
        await fixture.setHTTPStatus(404)
        let missing = AltStoreSourcesViewModel(defaults: defaults, cacheDirectory: cache.appendingPathComponent("missing"), automaticallyRefresh: false, loader: { try await fixture.load($0) })
        missing.adoptDiscovery([known.url: (same, Date().addingTimeInterval(-600))])
        await missing.refreshAllSources()
        let failedCount = await fixture.count
        await missing.refreshAllSources(onlyStale: true)
        let automaticCount = await fixture.count
        precondition(automaticCount == failedCount, "Automatic checks must back off unavailable publishers")
        await missing.refreshAllSources()
        let manualCount = await fixture.count
        precondition(manualCount > automaticCount, "An explicit pull-to-refresh must bypass automatic failure backoff")
        precondition(AltStoreSourceLoader.retryDelay(fail404) == 3600)
        await fixture.setHTTPStatus(nil)
        print("Catalog update checks passed: new/removed releases, one source of truth, Search revisions, shared offline cache, write ordering, forced refresh queuing, slow-source isolation and discovery cancellation")
    }

    private static func checkStartup122() async throws {
        let suite = "iPAStore.StartupChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let items = Array(IPAStoreDirectory.suggestions.filter { !$0.marketplaceOnly }.prefix(8))
        let selected = items.last!
        _ = IPADailyLibraryChoice(defaults: defaults).select(on: Date(), candidates: items.map(\.id), eligible: [selected.id])
        for (index, item) in items.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: ["name": "Cached Library", "apps": (0..<250).map { number in
                ["name": "Cached \(number)", "bundleIdentifier": "org.startup.lib\(index).app\(number)", "version": "1", "downloadURL": "https://example.org/\(number).ipa"]
            }])
            try data.write(to: directory.appendingPathComponent(AltStoreSourceLoader.cacheFileName(for: item.url)))
        }
        let fixture = RefreshFixture116()
        let discovery = IPADiscovery(suggestions: items, cacheDirectory: directory, defaults: defaults, loader: { try await fixture.load($0) })
        let started = Date()
        var snapshots: [Set<String>] = [], firstMilliseconds: Double?
        let observation = discovery.$sources.sink { snapshot in
            guard !snapshot.isEmpty else { return }
            if firstMilliseconds == nil { firstMilliseconds = Date().timeIntervalSince(started) * 1000 }
            snapshots.append(Set(snapshot.keys))
        }
        async let all: Void = discovery.load()
        async let selectedReload: Void = discovery.reload(IPAStoreReference(selected), onlyStale: true)
        _ = await (all, selectedReload)
        observation.cancel()
        precondition(snapshots.first == Set([selected.id]), "Today is published before the other cached libraries, even when saved last in the directory")
        precondition(discovery.sources.count == items.count && discovery.featured?.id == selected.id, "Fast startup retains every library and the stable daily selection")
        let requests = await fixture.count
        precondition(requests == 0, "Concurrent cache restoration and page loading must not refetch fresh catalogs")
        let reference = IPAStoreReference(selected), source = discovery.sources[selected.id]!
        let index = IPALibraryIndex()
        await index.prepare(reference: reference, source: source)
        precondition(index.entries(reference: reference, source: source).count == 250 && !index.browsingCategories(reference: reference, source: source).isEmpty)
        print("Startup checks passed: featured cache first in \(Int(firstMilliseconds ?? -1))ms, all \(items.count) caches in \(Int(Date().timeIntervalSince(started) * 1000))ms, stable selection, prepared shelves and zero network requests")
    }

    private static func checkProductSelection125() throws {
        let one = IPAStoreReference(url: URL(string: "https://example.org/product-one.json")!, name: "One", summary: "", publisher: nil)
        let two = IPAStoreReference(url: URL(string: "https://example.org/product-two.json")!, name: "Two", summary: "", publisher: nil)
        let data = Data(#"{"name":"Versions","apps":[{"name":"Versioned App","bundleIdentifier":"org.product.app","requiresJIT":true,"versions":[{"version":"2","downloadURL":"new.ipa","minOSVersion":"28.0"},{"version":"1","downloadURL":"old.ipa","minOSVersion":"17.0","maxOSVersion":"27.9","sha256":"old-checksum"}]}]}"#.utf8)
        let source = try AltStoreSourceLoader.decode(from: data, baseURL: one.url)
        let refreshed = try AltStoreSourceLoader.decode(from: data, baseURL: one.url)
        let current = IPACatalogPresentation.entries([(one, source.apps), (two, source.apps)])[0]
        let origin = IPAAppVariant(app: source.apps[0], store: two)
        let selected = IPAProductSelection.variant(in: current, origin: origin, selected: nil)
        precondition(selected.store.id == two.id, "Opening a library's app keeps its origin rather than switching to another mirror")
        let oldVersion = source.apps[0].versions.first { $0.version == "1" }!
        let key = IPAProductSelection.versionKey(oldVersion)
        let freshVariant = IPAAppVariant(app: refreshed.apps[0], store: two)
        let old = IPAProductSelection.version(in: freshVariant, selected: key)!
        let prepared = freshVariant.app.selecting(old)
        precondition(old.id != oldVersion.id && old.version == "1", "Release selection survives refreshed transient UUIDs")
        precondition(prepared.latestVersion?.downloadURL.lastPathComponent == "old.ipa" && prepared.latestVersion?.minOSVersion == "17.0" && prepared.latestVersion?.maxOSVersion == "27.9" && prepared.latestVersion?.sha256 == "old-checksum" && prepared.requiresJIT, "Selected release preserves its download, OS bounds, checksum and app runtime requirements")
        let explicit = IPAProductSelection.variant(in: current, origin: origin, selected: IPAProductSelection.variantKey(current.primary))
        precondition(explicit.store.id == one.id, "Explicit edition/library choice overrides the original library")
        let removed = IPACatalogPresentation.entries([(one, source.apps)])[0]
        precondition(IPAProductSelection.variant(in: removed, origin: origin, selected: nil).store.id == one.id, "A removed origin must not resurrect a stale library variant")
        precondition(IPAProductSelection.version(in: freshVariant, selected: "removed-version")?.version == "2", "Removed releases fall back to the publisher's current release")
        print("Product selection checks passed: origin retention, explicit edition choice, refreshed release identity, exact requirements/download and removed-origin/release fallback")
    }

    private static func checkReleaseNotes126() throws {
        func app(notes: String?, legacy: Bool = false) throws -> AltStoreSourceApp {
            var item: [String: Any] = ["name": "Notes", "bundleIdentifier": "org.notes", "localizedDescription": "A full app description, not release notes."]
            if legacy {
                item["version"] = "2.0"; item["downloadURL"] = "latest.ipa"
                if let notes { item["versionDescription"] = notes }
            } else {
                var latest: [String: Any] = ["version": "2.0", "downloadURL": "latest.ipa"]
                if let notes { latest["localizedDescription"] = notes }
                item["versions"] = [latest, ["version": "1.0", "downloadURL": "old.ipa", "localizedDescription": "Old update."]]
            }
            let data = try JSONSerialization.data(withJSONObject: ["name": "Library", "apps": [item]])
            return try AltStoreSourceLoader.decode(from: data, baseURL: URL(string: "https://example.org/notes.json")!).apps[0]
        }
        let latest = try app(notes: "Latest fixes.")
        precondition(IPAReleaseNotes.latest(in: latest) == "Latest fixes.", "Only latest release notes are shown, not concatenated versions")
        for notes in ["## Version 2.0\nLatest fixes.\n## Version 1.0\nOld changes.",
                      "**2.0**\nLatest fixes.\n**1.0**\nOld changes.",
                      "Latest fixes.\nv1.0 — Previous release\nOld changes.",
                      "# 1.0\nOld changes.\n# 2.0\nLatest fixes."] {
            let subject = try app(notes: notes)
            precondition(IPAReleaseNotes.latest(in: subject) == "Latest fixes.", "Cumulative changelogs stop at the next release")
        }
        let prose = "Supports version 1.0 and 2.0.\n1. Fixed playback\n2. Fixed search\nAll changes belong to this release."
        let proseApp = try app(notes: prose), missing = try app(notes: nil), legacy = try app(notes: nil, legacy: true)
        let legacyNotes = try app(notes: "Latest fixes.", legacy: true), oldOnly = try app(notes: "# 1.0\nOld changes.")
        precondition(IPAReleaseNotes.latest(in: proseApp) == prose, "Version mentions and numbered changes must not be discarded")
        precondition(IPAReleaseNotes.latest(in: missing) == nil, "Missing latest notes must not fall back to an older release")
        precondition(IPAReleaseNotes.latest(in: legacy) == nil, "A legacy app description must not be mislabeled as What's New")
        precondition(IPAReleaseNotes.latest(in: legacyNotes) == "Latest fixes.")
        precondition(IPAReleaseNotes.latest(in: oldOnly) == nil, "An older-only history must not be labeled as the latest update")
        print("Release notes checks passed: latest only, cumulative headings, reversed history, prose/bullets retained, legacy metadata and missing-note handling")
    }

    private static func checkUpdate131() throws {
        let suite = "iPAStore.Compatibility133." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = IPACompatibilityLaunchPolicy(defaults: defaults)
        defaults.set("1|100", forKey: "IPACompatibilityLaunch.v1.org.test.game")
        precondition(!policy.prefersCompatibility(identifier: "org.test.game", revision: "1|100"), "131's broad preferences must not force unrelated restart routes")
        precondition(IPACompatibilityLaunchPolicy.shouldRetry(.initialization, alreadyRetried: false))
        precondition(IPACompatibilityLaunchPolicy.shouldRetry(.exited(activationAge: nil), alreadyRetried: false))
        precondition(IPACompatibilityLaunchPolicy.shouldRetry(.exited(activationAge: 2.9), alreadyRetried: false))
        precondition(!IPACompatibilityLaunchPolicy.shouldRetry(.exited(activationAge: 3.1), alreadyRetried: false), "Running apps closing must not acquire a permanent legacy preference")
        precondition(!IPACompatibilityLaunchPolicy.shouldRetry(.exited(activationAge: .nan), alreadyRetried: false))
        precondition(!IPACompatibilityLaunchPolicy.shouldRetry(.timeout, alreadyRetried: false), "A timeout is not proof that compatibility launch is needed")
        precondition(!IPACompatibilityLaunchPolicy.shouldRetry(.initialization, alreadyRetried: true), "No automatic launch loop")
        policy.remember(identifier: "org.test.game", revision: "1|100")
        precondition(policy.prefersCompatibility(identifier: "ORG.TEST.GAME", revision: "1|100"))
        precondition(!policy.prefersCompatibility(identifier: "org.test.other", revision: "1|100"))
        precondition(!policy.prefersCompatibility(identifier: "org.test.game", revision: "2|200"), "New installs/versions must retry the normal launcher")
        policy.forget(identifier: "org.test.game")
        precondition(!policy.prefersCompatibility(identifier: "org.test.game", revision: "1|100"))
        var transition = IPAGuestLaunchTransition()
        let first = UUID(), second = UUID()
        precondition(transition.begin(first) && transition.coversStorefront)
        precondition(!transition.begin(second) && transition.requestID == first, "Duplicate launches must not overwrite the pending presentation")
        transition.didPresent(second)
        precondition(transition.coversStorefront, "An unrelated appearance cannot expose the storefront before the guest covers it")
        transition.cancel(first)
        precondition(!transition.coversStorefront && transition.requestID == nil, "Cancellation restores the storefront")
        precondition(transition.begin(second))
        transition.cancel(first); transition.didPresent(first)
        precondition(transition.coversStorefront && transition.requestID == second, "Late completion/cancellation must not erase the newer launch")
        transition.didPresent(second)
        precondition(!transition.coversStorefront && transition.requestID == nil)
        precondition(transition.begin(first)); transition.cancel()
        precondition(!transition.coversStorefront && transition.requestID == nil, "Closing before appearance must not leave an input-blocking cover")
        precondition(transition.beginReturn(second) && transition.coversStorefront)
        precondition(!transition.begin(first), "A return must cover the storefront until dismissal")
        transition.didPresent(first)
        precondition(transition.coversStorefront, "An old open callback cannot end the return fade")
        transition.didPresent(second)
        precondition(!transition.coversStorefront && transition.requestID == nil)
        precondition(transition.begin(first) && transition.beginReturn(first), "Close before the guest appears must still release the launch cover safely")
        transition.didPresent(first)
        let publisher = URL(string: "https://raw.githubusercontent.com/apptesters-org/AppTesters_Repo/main/apps.json")!
        let samples: [[String: Any]] = [
            ["type": 2, "size": "4194304"], ["category": "public.app-category.action-games", "size": 2048],
            ["primaryGenreId": 6011], ["genres": [["genreName": "Entertainment"]]],
            ["categories": ["", "Utilities"]], ["category": ["name": "Games"], "type": 1],
            ["type": 1, "size": -1], ["type": 2, "category": "Music", "size": "invalid"]
        ]
        let apps = samples.enumerated().map { index, fields -> [String: Any] in
            fields.merging(["name": "Entry \(index)", "bundleIdentifier": "org.test.entry\(index)", "version": "1", "downloadURL": "https://example.org/app.ipa"]) { _, new in new }
        }
        let data = try JSONSerialization.data(withJSONObject: ["name": "Test", "apps": apps])
        let source = try AltStoreSourceLoader.decode(from: data, baseURL: publisher)
        precondition(source.apps.count == 8, "Unknown category/size formats must never drop an app")
        let categories = source.apps.map { IPACatalogPresentation.category(for: $0) }
        precondition(categories == ["Games", "Games", "Music", "Entertainment", "Utilities", "Games", "More Apps", "Music"], "Read provider markers and common genre formats; explicit publisher category wins")
        precondition(source.apps[0].latestVersion?.size == 4194304 && source.apps[1].latestVersion?.size == 2048)
        precondition(source.apps[6].latestVersion?.size == nil && source.apps[7].latestVersion?.size == nil)
        let other = try AltStoreSourceLoader.decode(from: data, baseURL: URL(string: "https://example.org/apps.json")!)
        precondition(other.apps[0].category == nil, "AppTesters type markers must not be applied to unrelated libraries")
        if let fixture = ProcessInfo.processInfo.environment["IPA_TEST_APPTESTERS_FIXTURE"] {
            let live = try AltStoreSourceLoader.decode(from: Data(contentsOf: URL(fileURLWithPath: fixture)), baseURL: publisher)
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture))) as! [String: Any]
            let records = raw["apps"] as! [[String: Any]]
            let gameIDs = Set(records.filter { ($0["type"] as? Int) == 2 }.compactMap { $0["bundleIdentifier"] as? String })
            let represented = Set(live.apps.filter { IPACatalogPresentation.category(for: $0) == "Games" }.map(\.bundleIdentifier))
            precondition(gameIDs.isSubset(of: represented), "Every publisher-marked game must be reachable under Games")
            print("AppTesters snapshot: \(records.count) records; \(live.apps.count) decoded app/version records; \(gameIDs.count) unique marked game IDs covered")
        }
        print("Update133 compatibility selection, return-cover lifecycle/races and catalog checks passed")
    }

    private static func checkUpdate134() throws {
        var lifecycle = IPAGuestLifecycle()
        lifecycle.activate(at: 100)
        precondition(lifecycle.allowsCompatibilityDecision)
        lifecycle.interrupt()
        precondition(!lifecycle.allowsCompatibilityDecision && !lifecycle.claimResume())
        lifecycle.foreground()
        precondition(lifecycle.claimResume() && !lifecycle.claimResume(), "Only one automatic restart may be attempted after one interruption")
        lifecycle.activate(at: 1900)
        precondition(lifecycle.activationTime == 100, "Foregrounding cannot reset a long-running game into the startup-failure window")
        for failure in [IPACompatibilityLaunchPolicy.Failure.initialization, .exited(activationAge: nil), .exited(activationAge: 1), .timeout] {
            precondition(!IPACompatibilityLaunchPolicy.shouldRetry(failure, alreadyRetried: false, wasInterrupted: true), "Suspension can never become a compatibility decision")
        }
        precondition(!lifecycle.allowsCompatibilityDecision)
        lifecycle.interrupt(); lifecycle.foreground()
        precondition(lifecycle.claimResume(), "A later interruption has its own bounded recovery")
        let suite = "iPAStore.Resume134." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = IPAGuestResumeRecord(appFolder: "Game.app", dataFolder: "container-123", revision: "1|100", name: "Game")
        record.save(to: defaults)
        precondition(IPAGuestResumeRecord.read(from: defaults) == record, "Session identity survives process recreation without storing launch URLs or guest data")
        for path in ["../Game.app", "/Game.app", "..", "", "a/b", String(repeating: "x", count: 256)] {
            let bad = IPAGuestResumeRecord(appFolder: path, dataFolder: "data", revision: "1", name: "Game")
            defaults.set(try JSONEncoder().encode(bad), forKey: IPAGuestResumeRecord.key)
            precondition(IPAGuestResumeRecord.read(from: defaults) == nil, "Invalid restored paths must not reach the launcher")
        }
        defaults.set(Data(repeating: 65, count: 5000), forKey: IPAGuestResumeRecord.key)
        precondition(IPAGuestResumeRecord.read(from: defaults) == nil)
        let bundled = Bundle.main.url(forResource: "AppCategories", withExtension: "json")!
        let index = IPAAppCategoryIndex(data: try Data(contentsOf: bundled))
        precondition(index.category(for: "com.spotify.client") == "Music")
        precondition(index.category(for: "COM.GOOGLE.IOS.YOUTUBE") == "Photo & Video")
        precondition(index.category(for: "unknown.example") == nil)
        let sample = try AltStoreSourceLoader.decode(from: Data(#"{"name":"Genres","apps":[{"name":"Music","bundleIdentifier":"com.spotify.client","version":"1","downloadURL":"https://example.org/a.ipa"},{"name":"Publisher Wins","bundleIdentifier":"com.google.ios.youtube","category":"Utilities","version":"1","downloadURL":"https://example.org/b.ipa"},{"name":"No Genre","bundleIdentifier":"org.unknown.134","version":"1","downloadURL":"https://example.org/c.ipa"}]}"#.utf8), baseURL: URL(string: "https://example.org/feed.json")!)
        precondition(IPACatalogPresentation.category(for: sample.apps[0], index: index) == "Music")
        precondition(IPACatalogPresentation.category(for: sample.apps[1], index: index) == "Utilities", "Explicit publisher genre takes precedence over the supplemental index")
        precondition(IPACatalogPresentation.category(for: sample.apps[2], index: index) == "More Apps")
        if let fixture = ProcessInfo.processInfo.environment["IPA_TEST_APPTESTERS_FIXTURE"] {
            let source = try AltStoreSourceLoader.decode(from: Data(contentsOf: URL(fileURLWithPath: fixture)), baseURL: URL(string: "https://raw.githubusercontent.com/apptesters-org/AppTesters_Repo/main/apps.json")!)
            let library = IPAStoreReference(url: URL(string: "https://raw.githubusercontent.com/apptesters-org/AppTesters_Repo/main/apps.json")!, name: source.name, summary: "", publisher: nil)
            let entries = IPACatalogPresentation.entries([(library, source.apps)])
            let shelves = IPACatalogPresentation.libraryCategories(entries)
            print("AppTesters134 shelves: " + shelves.map { "\($0.name)=\($0.apps.count)" }.joined(separator: ", "))
            precondition(shelves.first { $0.name == "Entertainment" }!.apps.count > 50 && shelves.first { $0.name == "Utilities" }!.apps.count > 50)
            precondition(shelves.last?.apps.count == entries.count, "All publisher apps, including unclassified entries, must remain reachable")
        }
        print("Update134 interruption/recovery, restored-session validation and offline categories passed")
    }

    static func run() async throws {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPAOriginalCacheCheck-" + UUID().uuidString)
            let directory = root.appendingPathComponent("cache"), source = root.appendingPathComponent("original.ipa")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data(repeating: 1, count: 200).write(to: source)
            IPANativeOriginalCache.retain(source, identifier: "fixture.a", directory: directory, budget: 1000)
            let target = IPANativeOriginalCache.url(identifier: "fixture.a", directory: directory)
            let retained = try Data(contentsOf: target); let original = try Data(contentsOf: source); precondition(retained == original)
            try Data(repeating: 2, count: 240).write(to: source)
            IPANativeOriginalCache.retain(source, identifier: "fixture.a", directory: directory, budget: 1000)
            let replaced = try Data(contentsOf: target); let replacement = try Data(contentsOf: source); precondition(replaced == replacement)
            for n in 0..<8 { IPANativeOriginalCache.retain(source, identifier: "fixture.\(n)", directory: directory, budget: 1000) }
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            let total = try entries.reduce(0) { $0 + ((try $1.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) }
            precondition(total <= 1000 && entries.allSatisfy { $0.pathExtension == "ipa" })
            try Data(repeating: 3, count: 501).write(to: source)
            IPANativeOriginalCache.retain(source, identifier: "too-large", directory: directory, budget: 1000)
            precondition(!FileManager.default.fileExists(atPath: IPANativeOriginalCache.url(identifier: "too-large", directory: directory).path))
            let untouched = try Data(contentsOf: source); precondition(untouched == Data(repeating: 3, count: 501))
        }
        for mode in ["container", "independent", "unknown"] {
            for imported in [false, true] {
                for origin in ["account", "file", "unknown"] {
                    let expected = mode == "independent" && !(imported && origin == "file")
                    precondition(IPAInstalledModePolicy.needsFreeMode(selectedMode: mode, importedCertificate: imported, certificateOrigin: origin) == expected)
                }
            }
        }
        precondition(!IPAInstalledModePolicy.needsFreeMode(selectedMode: nil, importedCertificate: false, certificateOrigin: nil))
        try checkUpdate134()
        try checkUpdate131()
        precondition(IPAAppPresentationPolicy.mode(activated: false, layoutMatches: false, failed: false) == .starting, "An ordinary launch must not show recovery controls while waiting for orientation")
        precondition(IPAAppPresentationPolicy.mode(activated: false, layoutMatches: true, failed: false) == .starting, "Correct bounds alone cannot reveal an unactivated app")
        precondition(IPAAppPresentationPolicy.mode(activated: true, layoutMatches: true, failed: false) == .playing, "Reveal only an activated app with valid geometry")
        precondition(IPAAppPresentationPolicy.mode(activated: true, layoutMatches: false, failed: false) == .rotationRequired, "Unsupported rotations must retain a working return screen")
        precondition(IPAAppPresentationPolicy.mode(activated: true, layoutMatches: true, failed: true) == .failed, "A late ready frame must never hide an actual failure")
        try await checkLibraryRefreshes()
        try await checkCatalogUpdates119()
        try await checkStartup122()
        try checkProductSelection125()
        try checkReleaseNotes126()
        let shelfLibrary = IPAStoreReference(url: URL(string: "https://example.org/five-pages.json")!, name: "Shelf Library", summary: "", publisher: nil)
        let shelfJSON = try JSONSerialization.data(withJSONObject: ["name": "Shelf Library", "apps": (0..<20).map { number in
            ["name": "App \(number)", "bundleIdentifier": "org.shelf.app\(number)", "version": "1", "downloadURL": "https://example.org/\(number).ipa", "category": ["Entertainment", "Utilities", "Games", "Education"][number % 4]]
        }])
        let shelfSource = try AltStoreSourceLoader.decode(from: shelfJSON, baseURL: shelfLibrary.url)
        let shelfEntries = IPACatalogPresentation.entries([(shelfLibrary, shelfSource.apps)])
        let librarySections = IPACatalogPresentation.libraryCategories(shelfEntries)
        precondition(librarySections.map(\.name) == ["Entertainment", "Utilities", "Games", "All Apps"], "Library navigation has the four requested sections in order")
        precondition(librarySections.last?.apps.count == 20 && librarySections.last?.apps.contains(where: { $0.category == "Education" }) == true, "All Apps includes the full library and categories outside the three shelves")
        let shelfPreview = IPACatalogPresentation.shelfPages(librarySections.last!.apps)
        precondition(shelfPreview.count == 5 && shelfPreview.allSatisfy { $0.count == 3 } && Set(shelfPreview.flatMap { $0.map(\.id) }).count == 15, "The preview contains five pages of three distinct apps without truncating the full destination")
        precondition(IPACatalogPresentation.libraryCategories([]).isEmpty, "Empty libraries have no empty shelves")
        for entry in shelfEntries {
            let single = IPACatalogPresentation.libraryCategories([entry])
            precondition(single.map(\.name) == ["All Apps"] && single[0].apps.map(\.id) == [entry.id], "Single-app libraries show only All Apps, regardless of category")
        }
        let gamesOnly = shelfEntries.filter { $0.category == "Games" }
        let gameSections = IPACatalogPresentation.libraryCategories(gamesOnly)
        precondition(gameSections.map(\.name) == ["Games", "All Apps"] && gameSections.allSatisfy { !$0.apps.isEmpty }, "Unavailable categories are omitted without losing apps")
        let preparedLibrary = IPALibraryIndex()
        _ = preparedLibrary.entries(reference: shelfLibrary, source: shelfSource)
        for _ in 0..<200 where preparedLibrary.categories(reference: shelfLibrary, source: shelfSource).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(preparedLibrary.categories(reference: shelfLibrary, source: shelfSource).map(\.name) == librarySections.map(\.name))
        precondition(preparedLibrary.entries(reference: shelfLibrary, source: shelfSource).map(\.id) == shelfEntries.map(\.id), "Prepared rows and shelves belong to the same immutable source revision")
        let reducedJSON = try JSONSerialization.data(withJSONObject: ["name": "Shelf Library", "apps": [["name": "Only App", "bundleIdentifier": "org.shelf.only", "version": "2", "downloadURL": "https://example.org/only.ipa", "category": "Games"]]])
        let reducedSource = try AltStoreSourceLoader.decode(from: reducedJSON, baseURL: shelfLibrary.url)
        _ = preparedLibrary.entries(reference: shelfLibrary, source: reducedSource)
        for _ in 0..<200 where preparedLibrary.categories(reference: shelfLibrary, source: reducedSource).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(preparedLibrary.categories(reference: shelfLibrary, source: reducedSource).map(\.name) == ["All Apps"], "A refreshed single-app revision must not retain old category shelves")
        precondition(preparedLibrary.entries(reference: shelfLibrary, source: reducedSource).first?.app.bundleIdentifier == "org.shelf.only")
        precondition(preparedLibrary.cachedLibraryCount == 1 && preparedLibrary.cachedEntryCount == 1, "Refresh replaces the old prepared revision instead of retaining its full catalog")
        precondition(preparedLibrary.categories(reference: shelfLibrary, source: shelfSource).isEmpty, "An evicted revision cannot borrow shelves from the current revision")
        await preparedLibrary.prepare(reference: shelfLibrary, source: shelfSource)
        precondition(preparedLibrary.categories(reference: shelfLibrary, source: shelfSource).count == 4, "An explicitly revisited revision can be reconstructed")
        print("Library section checks passed: hidden empty shelves, single-app All Apps, prepared categories, full-list retention and five-page preview")
        let listingData = Data(#"{"results":[{"kind":"software","bundleId":"org.example.exact","artworkUrl512":"https://example.org/icon.png","screenshotUrls":["https://example.org/preview.jpg","file:///private/photo.png"],"averageUserRating":4.6,"userRatingCount":123,"contentAdvisoryRating":"9+"}]}"#.utf8)
        let exact = IPAProductMetadata.decode(listingData, matching: "org.example.exact")
        precondition(exact?.screenshots.count == 1 && exact?.rating == 4.6, "Use only secure artwork from an exact listing identity")
        precondition(IPAProductMetadata.decode(listingData, matching: "org.example.lookalike") == nil, "A similar name or different bundle cannot borrow artwork or ratings")
        precondition(IPAProductMetadata.decode(Data(repeating: 32, count: 2 * 1024 * 1024 + 1), matching: "org.example.exact") == nil, "Bound metadata parsing")
        precondition(IPAInstallIssue.launch("code signature invalid").action == .signing, "Signature failures direct to signing recovery")
        precondition(IPAInstallIssue.launch("Library not loaded: dyld").action == .compatibleBuild, "Missing runtimes do not claim re-signing fixes them")
        precondition(IPAInstallIssue.launch("JIT unavailable").action == .compatibleBuild, "JIT guidance is distinct from certificate setup")
        precondition(IPAInstallIssue.independentSetup.action == .containerMode, "Independent-install setup offers an explicit container-mode recovery instead of a certificate-import loop")
        let merged = IPAStoreDirectory.mergingSnapshot(Data(#"{"libraries":[{"id":"snapshot-ish","name":"iSH","summary":"Shell","url":"https://ish.app/altstore.json","publisher":"https://ish.app","developer":"iSH","artwork":"https://ish.app/assets/icon-full.png","marketplaceOnly":false,"webURL":"https://ish.app/altstore.json"}]}"#.utf8))
        precondition(merged.first(where: { $0.id == "ish" })?.artwork?.absoluteString == "https://ish.app/assets/icon-full.png", "Merging a known library must retain its publisher artwork")
        let base = URL(string: "https://example.org/source.json")!
        func source(_ apps: String) throws -> AltStoreSource {
            try AltStoreSourceLoader.decode(from: Data("{\"name\":\"Test\",\"apps\":[\(apps)]}".utf8), baseURL: base)
        }
        let stable = try source("""
        {"name":"Example","bundleIdentifier":"org.example.app","category":"utilities","version":"1","downloadURL":"app.ipa"},
        {"name":"Same Name","bundleIdentifier":"org.other.app","version":"1","downloadURL":"other.ipa"}
        """)
        let beta = try source("""
        {"name":"Example","bundleIdentifier":"org.example.app.Beta","beta":true,"version":"2","downloadURL":"beta.ipa"},
        {"name":"Same Name","bundleIdentifier":"org.another.app","version":"1","downloadURL":"another.ipa"}
        """)
        let first = IPAStoreReference(url: base, name: "First", summary: "", publisher: nil)
        let second = IPAStoreReference(url: URL(string: "https://example.net/source.json")!, name: "Second", summary: "", publisher: nil)
        let entries = IPACatalogPresentation.entries([(second, beta.apps), (first, stable.apps), (first, stable.apps)])
        let preparedSearch = entries.map(IPASearchDocument.init)
        for query in ["Example", "Second", "Utilities", "missing"] {
            let prepared = Set(IPASearchDocument.matches(query, documents: preparedSearch).map { entries[$0].id })
            let previous = Set(IPACatalogPresentation.search(query, in: entries).map(\.id))
            precondition(prepared == previous, "Prepared search preserves app, developer, category and library matches")
        }
        let largeSearch = Array(repeating: preparedSearch, count: 10000).flatMap { $0 }
        let searchStarted = Date()
        let largeMatches = IPASearchDocument.matches("Example", documents: largeSearch)
        precondition(!largeMatches.isEmpty)
        print("Prepared Search: \(largeSearch.count) records in \(Int(Date().timeIntervalSince(searchStarted) * 1000)) ms")
        precondition(entries.count == 3, "Group preview editions, retain unrelated same-name apps and deduplicate repeated feeds")
        let example = entries.first { $0.id == "org.example.app" }!
        precondition(example.variants.count == 2 && !example.primary.isPreview, "Standard edition is preferred even when a preview feed comes first")
        precondition(example.primary.store == first, "Preserve the actual origin of the selected edition")
        precondition(example.category == "Utilities", "Use publisher-provided categories")
        precondition(IPACatalogPresentation.search("EXAMPLE", in: entries).count == 1, "Search returns one app family")
        precondition(IPACatalogPresentation.search("First", in: entries).contains { $0.id == example.id }, "Library names are searchable")
        precondition(IPACatalogPresentation.search("  ", in: entries).isEmpty, "Empty queries are browsing, not synthetic results")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeDST = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let afterDST = calendar.date(byAdding: .day, value: 1, to: beforeDST)!
        let sameDay = calendar.date(byAdding: .hour, value: 3, to: beforeDST)!
        let today = IPACatalogPresentation.featuredIndex(on: beforeDST, calendar: calendar, count: 7)!
        precondition(IPACatalogPresentation.featuredIndex(on: sameDay, calendar: calendar, count: 7) == today, "Feature remains stable within the local day")
        precondition(IPACatalogPresentation.featuredIndex(on: afterDST, calendar: calendar, count: 7) == (today + 1) % 7, "Daily feature survives daylight-saving transitions")
        precondition(IPACatalogPresentation.featuredIndex(on: calendar.date(byAdding: .day, value: 7, to: beforeDST)!, calendar: calendar, count: 7) == today, "Features loop over the directory")
        precondition(IPACatalogPresentation.featuredIndex(on: beforeDST, count: 0) == nil, "An empty directory cannot select an invalid feature")
        let directoryFixture = Data("""
        {"libraries":[{"id":"hub-utm","name":"Duplicate","summary":"","url":"https://alt.getutm.app","publisher":"https://getutm.app","marketplaceOnly":false},{"id":"hub-pal","name":"Marketplace","summary":"Publisher editions","url":"https://example.org/pal.json","publisher":"https://example.org","marketplaceOnly":true}]}
        """.utf8)
        let mergedDirectory = IPAStoreDirectory.mergingSnapshot(directoryFixture)
        precondition(mergedDirectory.filter { $0.url.host == "alt.getutm.app" }.count == 1, "Merge curated and registry libraries by canonical URL")
        precondition(mergedDirectory.contains { $0.id == "hub-pal" && $0.marketplaceOnly }, "Marketplace-only listings retain their installation restrictions")
        let suite = "IPAStore.ReleaseChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let choices = ["one", "two", "three", "four"]
        let daily = IPADailyLibraryChoice(defaults: defaults)
        let firstChoice = daily.select(on: beforeDST, calendar: calendar, candidates: choices, eligible: ["four"])!
        precondition(firstChoice == "four")
        precondition(daily.select(on: sameDay, calendar: calendar, candidates: choices, eligible: Set(choices)) == firstChoice, "Newly arriving feeds cannot replace today's visible feature")
        precondition(IPADailyLibraryChoice(defaults: defaults).select(on: sameDay, calendar: calendar, candidates: choices, eligible: Set(choices)) == firstChoice, "Daily choice survives reopening")
        precondition(IPADailyLibraryChoice(defaults: defaults).saved(on: sameDay, calendar: calendar, candidates: choices) == firstChoice, "Reopening can present the saved feature before large catalogs decode")
        precondition(daily.saved(on: afterDST, calendar: calendar, candidates: choices) == nil, "A new day must not present yesterday's saved feature")
        let nextChoice = daily.select(on: afterDST, calendar: calendar, candidates: choices, eligible: Set(choices))
        let expectedChoice = choices[IPACatalogPresentation.featuredIndex(on: afterDST, calendar: calendar, count: choices.count)!]
        precondition(nextChoice == expectedChoice, "Local midnight advances the rotation even across DST")
        precondition(daily.select(on: afterDST, calendar: calendar, candidates: choices, eligible: []) == nil, "An unavailable directory has no invalid feature")
        precondition(daily.select(on: afterDST, calendar: calendar, candidates: choices, eligible: Set(choices)) == nextChoice, "Temporary empty state does not erase the saved daily choice")
        let history = IPASearchHistory(defaults: defaults)
        history.record(" Delta "); history.record("delta")
        precondition(history.terms == ["delta"], "Recent searches are trimmed and deduplicated without case sensitivity")
        for number in 0..<12 { history.record("Query \(number)") }
        precondition(history.terms.count == 8 && history.terms.first == "Query 11", "History is bounded and ordered by recency")
        let reloaded = IPASearchHistory(defaults: defaults)
        precondition(reloaded.terms == history.terms, "Recent searches persist")
        reloaded.remove("Query 11"); precondition(!reloaded.terms.contains("Query 11"))
        reloaded.clear(); precondition(IPASearchHistory(defaults: defaults).terms.isEmpty)
        let activity = IPAActivityHistory(defaults: defaults)
        var historyPublications = 0
        let historyObserver = activity.$recent.dropFirst().sink { _ in historyPublications += 1 }
        activity.viewed(example); activity.viewed(example)
        precondition(historyPublications == 2, "Opening a page publishes one complete recent-history snapshot, not intermediate remove/insert states")
        historyObserver.cancel()
        precondition(activity.recent.count == 1 && activity.downloads.isEmpty, "Viewing an app never pretends it was downloaded")
        activity.downloaded(example.primary)
        precondition(activity.wasDownloaded(example.app.bundleIdentifier.uppercased()), "Cloud redownload state follows successful install history, without case sensitivity")
        activity.downloaded(example.primary)
        precondition(activity.downloads.count == 1, "Updating an app does not duplicate its download record")
        await activity.flush()
        let activityReloaded = IPAActivityHistory(defaults: defaults)
        precondition(activityReloaded.recent == activity.recent && activityReloaded.downloads == activity.downloads, "App history persists with its original library")
        precondition(activityReloaded.wasDownloaded(example.app.bundleIdentifier.uppercased()), "Fast redownload lookup is restored from saved history")
        activityReloaded.clearRecent()
        precondition(activityReloaded.recent.isEmpty && activityReloaded.downloads.count == 1, "Clearing recent apps leaves download history intact")
        activityReloaded.downloaded(IPAAppVariant(app: example.app, store: shelfLibrary))
        activityReloaded.remove(activityReloaded.downloads[0], downloaded: true)
        precondition(activityReloaded.wasDownloaded(example.app.bundleIdentifier), "Removing one library's record retains another library's redownload state")
        activityReloaded.remove(activityReloaded.downloads[0], downloaded: true)
        precondition(activityReloaded.downloads.isEmpty && !activityReloaded.wasDownloaded(example.app.bundleIdentifier), "Removing the last record clears fast redownload lookup")
        await activityReloaded.flush()
        let clearedHistory = IPAActivityHistory(defaults: defaults)
        precondition(clearedHistory.recent.isEmpty && clearedHistory.downloads.isEmpty, "Older asynchronous writes must not resurrect cleared history")
        precondition(defaults.array(forKey: "LCAltStoreSourceURLs") == nil, "Discovery and search do not subscribe to libraries")
        let handoffRoot = FileManager.default.temporaryDirectory.appendingPathComponent("IPAStoreHandoff-\(UUID())", isDirectory: true)
        let childDocuments = handoffRoot.appendingPathComponent("SideStore/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: childDocuments, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: handoffRoot) }
        let connectionDate = Date(timeIntervalSince1970: 1_800_000_000)
        let childStatus: [String: Any] = ["pairingImported": true, "accountStored": true, "certificateAvailable": true, "connectionCheckedAt": connectionDate, "unexpectedSecret": "must-not-cross"]
        let handoffFile = childDocuments.appendingPathComponent("IPAStoreSetupStatus.plist")
        try PropertyListSerialization.data(fromPropertyList: childStatus, format: .binary, options: 0).write(to: handoffFile)
        let consumed = IPASigningSetupHandoff.consume(hostDocuments: handoffRoot)
        precondition(consumed?.pairingImported == true && consumed?.accountStored == true && consumed?.certificateAvailable == true && consumed?.connectionCheckedAt == connectionDate, "Read the child process's real Documents path")
        precondition(consumed?.propertyList["unexpectedSecret"] == nil, "Only readiness flags and connection time cross into host defaults")
        let liveFile = childDocuments.appendingPathComponent("IPAStoreSetupReadiness.plist")
        let live = ["pairingImported": true, "accountStored": false, "certificateAvailable": false]
        try PropertyListSerialization.data(fromPropertyList: live, format: .binary, options: 0).write(to: liveFile)
        let dismissed = IPASigningSetupHandoff.consume(hostDocuments: handoffRoot)
        precondition(dismissed?.pairingImported == true && dismissed?.accountStored == false,
                     "Returning with Back or swiping preserves completed steps")
        precondition(!FileManager.default.fileExists(atPath: liveFile.path), "Consume the live snapshot only once")
        precondition(!FileManager.default.fileExists(atPath: handoffFile.path) && IPASigningSetupHandoff.consume(hostDocuments: handoffRoot) == nil, "Consume once without clearing saved host readiness on subsequent appearances")
        let certificateInbox = childDocuments.appendingPathComponent("IPAStoreCertificateImport.p12")
        let sampleCertificate = Data([1, 2, 3, 4])
        try sampleCertificate.write(to: certificateInbox)
        precondition(IPASigningSetupHandoff.consumeCertificate(hostDocuments: handoffRoot) == sampleCertificate, "Certificate selected in pairing routes to the host password screen")
        precondition(!FileManager.default.fileExists(atPath: certificateInbox.path), "Certificate handoff is consumed only once")
        let privateOriginal = handoffRoot.appendingPathComponent("original.p12")
        try sampleCertificate.write(to: privateOriginal)
        try FileManager.default.createSymbolicLink(at: certificateInbox, withDestinationURL: privateOriginal)
        precondition(IPASigningSetupHandoff.consumeCertificate(hostDocuments: handoffRoot) == nil, "Reject symlink certificate inbox")
        let originalBytes = try Data(contentsOf: privateOriginal)
        precondition(originalBytes == sampleCertificate, "Do not remove the user original")
        try Data(repeating: 1, count: 2 * 1024 * 1024 + 1).write(to: certificateInbox)
        precondition(IPASigningSetupHandoff.consumeCertificate(hostDocuments: handoffRoot) == nil, "Bound certificate reads")
        let legacyFile = handoffRoot.appendingPathComponent("SideStore/IPAStoreSetupStatus.plist")
        try PropertyListSerialization.data(fromPropertyList: childStatus, format: .xml, options: 0).write(to: legacyFile)
        precondition(IPASigningSetupHandoff.consume(hostDocuments: handoffRoot) != nil, "Accept the legacy handoff path")
        try Data("invalid".utf8).write(to: handoffFile)
        precondition(IPASigningSetupHandoff.consume(hostDocuments: handoffRoot) == nil, "Malformed status cannot fabricate setup readiness")
        try Data(repeating: 65, count: 5000).write(to: handoffFile)
        precondition(IPASigningSetupHandoff.consume(hostDocuments: handoffRoot) == nil, "Bound handoff reads")
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let expiration = created.addingTimeInterval(7 * 86_400)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CreationDate": created, "ExpirationDate": expiration], format: .xml, options: 0)
        var embedded = Data([0x30, 0x82, 0x01, 0x00]); embedded.append(plist); embedded.append(contentsOf: [0, 1, 2])
        let profile = IPAProvisioningMetadata.read(from: embedded)!
        precondition(IPARenewalPolicy.successMessage(profile: profile, now: created).contains("7 days"), "A fresh seven-day profile reports its real remaining lifetime")
        precondition(IPARenewalPolicy.successMessage(profile: profile, now: created.addingTimeInterval(5 * 86_400)).contains("2 days"), "Success feedback must not reset an older profile to seven days")
        precondition(!IPARenewalPolicy.successMessage(profile: nil, now: created).contains("7 days"), "Missing profile metadata cannot invent a new expiry")
        precondition(!IPARenewalPolicy.successMessage(profile: profile, now: expiration).contains("7 days"), "An expired profile cannot be presented as a renewed seven-day signature")
        for value in [nil, "", "  ", "Unknown", "not provided", "N/A", "—"] as [String?] {
            precondition(IPACatalogPresentation.displayValue(value) == nil, "Absent publisher metadata must not produce an empty information cell")
        }
        precondition(IPACatalogPresentation.displayValue("  Example Developer \n") == "Example Developer", "Real publisher metadata remains visible")
        precondition(profile.expiresAt == expiration && profile.createdAt == created, "Use actual embedded provisioning metadata")
        precondition(IPAProvisioningMetadata.read(from: Data("invalid profile".utf8)) == nil, "Invalid profiles cannot invent an expiration")
        let due = IPARenewalPolicy.targetDate(for: profile)
        precondition(IPARenewalPolicy.decide(automatic: true, ready: true, profile: profile, lastAttempt: nil, now: created) == .waiting(until: due), "Wait until the renewal window")
        precondition(IPARenewalPolicy.decide(automatic: true, ready: true, profile: profile, lastAttempt: nil, now: due) == .due, "Renew before expiry")
        precondition(IPARenewalPolicy.decide(automatic: false, ready: true, profile: profile, lastAttempt: nil, now: expiration) == .manual, "Manual mode never silently schedules signing")
        precondition(IPARenewalPolicy.decide(automatic: true, ready: false, profile: profile, lastAttempt: nil, now: due) == .setupRequired, "Do not claim readiness before setup")
        precondition(IPARenewalPolicy.decide(automatic: true, ready: true, profile: nil, lastAttempt: nil, now: due) == .expirationUnknown, "No fabricated seven-day expiry")
        precondition(IPARenewalPolicy.decide(automatic: true, ready: true, profile: profile, lastAttempt: due, now: due.addingTimeInterval(60)) == .retryAfter(due.addingTimeInterval(IPARenewalPolicy.retryInterval)), "Back off instead of repeatedly signing")
        precondition(IPACompatibility.compare("27.2", "27.2.0") == .orderedSame)
        precondition(IPACompatibility.compare("27.10", "27.2") == .orderedDescending, "Compare numeric components, not decimal or lexical strings")
        precondition(IPACompatibility.issue(minimum: "28", maximum: nil, current: "27.2") != nil)
        precondition(IPACompatibility.issue(minimum: nil, maximum: "16.9", current: "27.2") != nil)
        precondition(IPACompatibility.issue(minimum: "garbage", maximum: nil, current: "27.2") != nil)
        precondition(IPACompatibility.issue(minimum: "15", maximum: "28", current: "27.2") == nil)
        let metadata = try source("""
        {"name":"Metadata","bundleIdentifier":"org.test.metadata","requiresJIT":true,"headerURL":"art/header.jpg","screenshots":{"iphone":[{"imageURL":"art/shot.jpg"}]},"versions":[{"version":"1","downloadURL":"file.ipa","minOSVersion":"17.0","maxOSVersion":"27.9","sha256":"abc"}]},
        {"name":"Unsafe","bundleIdentifier":"org.test.unsafe","iconURL":"file:///private/secret","version":"1","downloadURL":"javascript:alert(1)"}
        """)
        precondition(metadata.apps[0].latestVersion?.minOSVersion == "17.0" && metadata.apps[0].latestVersion?.maxOSVersion == "27.9")
        precondition(metadata.apps[0].requiresJIT, "Retain explicit runtime requirements")
        precondition(metadata.apps[0].selecting(metadata.apps[0].versions[0]).requiresJIT, "Version selection retains app requirements")
        precondition(metadata.apps[0].latestVersion?.sha256 == "abc", "Retain checksums for verification, reject invalid values at install time")
        precondition(metadata.apps[0].headerURL?.absoluteString == "https://example.org/art/header.jpg" && metadata.apps[0].screenshots.count == 1)
        precondition(metadata.apps[1].iconURL == nil && metadata.apps[1].latestVersion == nil, "Feeds cannot turn local files or executable schemes into downloads")
        precondition(AltStoreSourceLoader.canonical(URL(string: "https://EXAMPLE.org:443/#x")!) == "https://example.org/")
        precondition(AltStoreSourceLoader.canonical(URL(string: "https://example.org/feed/?edition=1")!) != AltStoreSourceLoader.canonical(URL(string: "https://example.org/feed?edition=1")!), "Do not collapse distinct non-root paths")
        let binaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("IPABinaryChecks-\(UUID())")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: binaryDirectory) }
        func binary(_ name: String, encrypted: Bool = false, cpu: UInt32 = 0x0100000c, minimum: UInt32 = 0x110000, platform: UInt32 = 2) throws -> URL {
            var data = Data()
            let words: [UInt32] = [0xfeedfacf, cpu, 0, 2, 2, 48, 0, 0, 0x32, 24, platform, minimum, minimum, 0, 0x2c, 24, 0, 0, encrypted ? 1 : 0, 0]
            for word in words { var value = word.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            let url = binaryDirectory.appendingPathComponent(name); try data.write(to: url); return url
        }
        let valid = try binary("valid")
        try IPABinaryInspector.validate(valid, currentOS: "27.2", executable: true)
        for url in [try binary("encrypted", encrypted: true), try binary("simulator", platform: 7), try binary("newer", minimum: 0x1c0000), try binary("intel", cpu: 0x01000007)] {
            do { try IPABinaryInspector.validate(url, currentOS: "27.2", executable: true); preconditionFailure("Reject incompatible binary \(url.lastPathComponent)") } catch { }
        }
        let malformed = binaryDirectory.appendingPathComponent("truncated")
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: malformed)
        do { _ = try IPABinaryInspector.inspect(malformed); preconditionFailure("Reject truncated headers") } catch { }
        let current = binaryDirectory.appendingPathComponent("Current.app", isDirectory: true)
        let prepared = binaryDirectory.appendingPathComponent(".candidate.pending", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: current.appendingPathComponent("version"))
        try Data("new".utf8).write(to: prepared.appendingPathComponent("version"))
        try IPAInstallCommit.replace(prepared: prepared, current: current)
        let committedVersion = try String(contentsOf: current.appendingPathComponent("version"), encoding: .utf8)
        let retainedVersion = try String(contentsOf: prepared.appendingPathComponent("version"), encoding: .utf8)
        precondition(committedVersion == "new" && retainedVersion == "old", "Atomic replacement preserves the existing launch path and retains the old package for cleanup")
        do { try IPAInstallCommit.replace(prepared: binaryDirectory.appendingPathComponent("missing"), current: current); preconditionFailure("Missing candidate cannot replace an existing app") } catch { }
        let afterFailedCommit = try String(contentsOf: current.appendingPathComponent("version"), encoding: .utf8)
        precondition(afterFailedCommit == "new", "A failed update keeps the installed app intact")
        precondition(IPACompatibility.requiresJIT(identifier: "com.utmapp.UTM"))
        precondition(!IPACompatibility.requiresJIT(identifier: "com.utmapp.UTM-SE"))
        precondition(IPACompatibility.requiresJIT(identifier: "org.publisher.app", declared: true))
        let libraryCache = IPALibraryIndex()
        precondition(libraryCache.entries(reference: first, source: stable).isEmpty, "Cold library work must not block navigation")
        for _ in 0..<100 where libraryCache.revision == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        let cachedLibrary = libraryCache.entries(reference: first, source: stable)
        precondition(cachedLibrary.count == stable.apps.count)
        _ = libraryCache.entries(reference: second, source: beta)
        for _ in 0..<100 where libraryCache.revision < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!libraryCache.entries(reference: second, source: beta).isEmpty)
        precondition(libraryCache.entries(reference: second, source: beta).allSatisfy { $0.variants.allSatisfy { $0.store.id == second.id } }, "A featured library's shelves cannot contain other libraries' apps")
        let allApps = IPAAllAppsIndex()
        allApps.rebuild(subscribed: [.init(url: first.url, source: stable)], discovered: ["utm": beta])
        for _ in 0..<100 where allApps.entries.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(allApps.entry(identifier: "org.another.app") != nil, "Browse All Apps includes discovered libraries that were never subscribed")
        precondition(allApps.more(in: first.id, excluding: "absent").allSatisfy { $0.variants.allSatisfy { $0.store.id == first.id } }, "Cached publisher recommendations preserve library identity")
        precondition(allApps.entry(identifier: "org.other.app") != nil, "Browse All Apps retains user-added libraries")
        precondition(defaults.array(forKey: "LCAltStoreSourceURLs") == nil, "Global browsing must not subscribe the user to a library")
        let early = IPAResultGate<Int>()
        precondition(early.finish(.success(7)))
        precondition(!early.finish(.success(8)))
        let earlyValue = try await early.wait()
        precondition(earlyValue == 7, "Early completion is retained and duplicate completion ignored")
        let racing = IPAResultGate<Int>()
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for number in 0..<64 { group.addTask { racing.finish(.success(number)) } }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        precondition(winners == 1, "Concurrent callbacks finish exactly once")
        let winningValue = try await racing.wait()
        precondition((0..<64).contains(winningValue))
        let cancelled = IPAResultGate<Void>()
        cancelled.finish(.failure(CancellationError()))
        do { try await cancelled.wait(); preconditionFailure("Cancellation must be delivered") } catch is CancellationError {} catch { throw error }
        print("Release catalog, binary compatibility, atomic replacement, renewal and callback-race checks passed: origins, variants, categories, search, local daily rotation, DST, recent-search persistence, empty subscriptions")
    }
}

private actor RefreshFixture116 {
    private(set) var count = 0
    private var mode = 0
    func setMode(_ mode: Int) { self.mode = mode }
    func load(_ url: URL) async throws -> (AltStoreSource, Data) {
        count += 1
        let mode = mode
        try await Task.sleep(nanoseconds: 30_000_000)
        if mode == 1 { throw URLError(.notConnectedToInternet) }
        if mode == 2 { throw CancellationError() }
        let data = Data(#"{"name":"Test Library","apps":[{"name":"App","bundleIdentifier":"org.example.app","version":"1","downloadURL":"app.ipa"}]}"#.utf8)
        return (try AltStoreSourceLoader.decode(from: data, baseURL: url), data)
    }
}

private actor UpdateFixture119 {
    private var httpStatus: Int?
    func setHTTPStatus(_ value: Int?) { httpStatus = value }
    private var generation = 1
    private var failure = false
    private(set) var count = 0
    func setGeneration(_ value: Int) { generation = value }
    func setFailure(_ value: Bool) { failure = value }
    func load(_ url: URL) async throws -> (AltStoreSource, Data) {
        count += 1
        let version = generation, failing = failure, status = httpStatus
        try await Task.sleep(nanoseconds: 25_000_000)
        if let status { throw NSError(domain: "iPAStore.DownloadHTTP", code: status) }
        if failing { throw URLError(.notConnectedToInternet) }
        let extraID = version == 1 ? "org.example.removed" : "org.example.new"
        let extraName = version == 1 ? "Removed App" : "New App"
        let data = try JSONSerialization.data(withJSONObject: ["name": "Updating Library", "apps": [
            ["name": "Updated App", "bundleIdentifier": "org.example.updated", "version": String(version), "downloadURL": "https://example.org/v\(version).ipa"],
            ["name": extraName, "bundleIdentifier": extraID, "version": "1", "downloadURL": "https://example.org/extra.ipa"]
        ]], options: [.sortedKeys])
        return (try AltStoreSourceLoader.decode(from: data, baseURL: url), data)
    }
}
