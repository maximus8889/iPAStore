import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum IPADistribution {
    static let repository = "maximus8889/iPAStore"
    static let latestReleaseEndpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    struct Release: Decodable {
        let tag: String
        let page: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
            case draft, prerelease, assets
        }

        struct Asset: Decodable {
            let name: String
            let state: String
            let size: Int64
            let download: URL
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, state, size, digest
                case download = "browser_download_url"
            }
        }

        var version: String { String(tag.dropFirst().prefix { $0 != "-" }) }

        var build: Int? {
            guard !draft, !prerelease,
                  tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+-build[0-9]+$"#, options: .regularExpression) != nil,
                  page.absoluteString == "https://github.com/\(repository)/releases/tag/\(tag)" else { return nil }
            return tag.components(separatedBy: "-build").last.flatMap(Int.init)
        }

        var package: Asset? {
            guard build != nil else { return nil }
            let download = "https://github.com/\(repository)/releases/download/\(tag)/iPAStore.ipa"
            return assets.first {
                $0.name == "iPAStore.ipa" && $0.state == "uploaded" && $0.size > 0 && $0.download.absoluteString == download
            }
        }
    }

    static func latestRelease() async throws -> Release? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: latestReleaseEndpoint)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200, data.count <= 1_048_576 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.build != nil else { throw URLError(.cannotParseResponse) }
        return release
    }

    static func download(_ package: Release.Asset, build: Int,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let transfer = IPADownloadTransfer(maximumBytes: package.size, expectedBytes: package.size) { update in
            progress(min(1, Double(update.received) / Double(package.size)))
        }
        let file = try await transfer.download(package.download)
        defer { try? FileManager.default.removeItem(at: file) }

        let host = transfer.resolvedURL?.host
        guard transfer.resolvedURL?.scheme == "https",
              host == "github.com" || host?.hasSuffix(".githubusercontent.com") == true else {
            throw URLError(.badServerResponse)
        }
        guard Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == package.size else {
            throw URLError(.cannotDecodeContentData)
        }
        if let digest = package.digest {
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            var hash = SHA256()
            while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == "sha256:" + actual else { throw URLError(.cannotDecodeContentData) }
        }
        try Task.checkCancellation()

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iPAStore-Update-\(UUID().uuidString)", isDirectory: true)
        let destination = folder.appendingPathComponent("iPAStore-build\(build).ipa")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

private struct IPAUpdateFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "ipa") ?? .data) { file in
            SentTransferredFile(file.url)
        }
    }
}

struct IPAUpdatesView: View {
    @Environment(\.ipaAccent) private var accent
    @State private var checking = false
    @State private var checkMessage: LocalizedStringKey?
    @State private var release: IPADistribution.Release?
    @State private var confirmingDownload = false
    @State private var work: Task<Void, Never>?
    @State private var progress: Double?
    @State private var activeDownloadID: UUID?
    @State private var downloadedFile: URL?
    @State private var downloadFailed = false

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var installedBuild: Int? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                installedCard
                if let checkMessage {
                    Text(checkMessage).ipaFont(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("update-check-status")
                }
                if let release, let build = release.build {
                    releaseCard(release, build: build)
                }

            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(IPAStyle.canvas)
        .navigationTitle("Updates").navigationBarTitleDisplayMode(.inline).ipaNativePage()
        .alert("Download iPAStore?", isPresented: $confirmingDownload, presenting: release) { release in
            Button("Download") {
                guard let build = release.build, let package = release.package else { return }
                download(package, build: build)
            }
            Button("Not Now", role: .cancel) {}
        } message: { release in
            if let build = release.build, let package = release.package {
                Text("Version \(release.version), build \(build) · \(ByteCountFormatter.string(fromByteCount: package.size, countStyle: .file)) from GitHub.")
            }
        }
        .onDisappear {
            work?.cancel()
            clearDownloadedFile()
        }
    }

    private var installedCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 32, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 62, height: 62)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("iPAStore").ipaFont(.title2, weight: .bold).accessibilityAddTraits(.isHeader)
                    if let installedBuild {
                        Text("Installed · Version \(installedVersion) (\(installedBuild))")
                            .ipaFont(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Button(action: check) {
                HStack(spacing: 6) {
                    if checking { ProgressView().controlSize(.small) }
                    Text(checking ? "Checking…" : "Check for Updates")
                }
            }
            .buttonStyle(IPAPillStyle(prominent: true, compact: true))
            .disabled(work != nil)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private func releaseCard(_ release: IPADistribution.Release, build: Int) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(installedBuild.map { build > $0 } == true ? "Update Available" : "Latest Release")
                    .ipaFont(.headline, weight: .semibold).accessibilityAddTraits(.isHeader)
                Text("Version \(release.version) · Build \(build)")
                    .ipaFont(.subheadline).foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: progress) {
                    Text(progress < 1 ? "Downloading…" : "Verifying…")
                        .ipaFont(.subheadline, weight: .semibold)
                }
                Button("Cancel Download") { work?.cancel() }
                    .ipaFont(.subheadline)
            } else if let downloadedFile {
                Label("Download Complete", systemImage: "checkmark.circle.fill")
                    .ipaFont(.subheadline, weight: .semibold).foregroundStyle(.green)
                ShareLink(item: IPAUpdateFile(url: downloadedFile), preview: SharePreview(downloadedFile.lastPathComponent)) {
                    Label("Save or Share IPA", systemImage: "square.and.arrow.up")
                        .ipaFont(.subheadline, weight: .semibold)
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                Text("To update in place, use the same signer and keep your current copy installed.")
                    .ipaFont(.footnote).foregroundStyle(.secondary)
            } else if let installedBuild, build > installedBuild, let package = release.package {
                if downloadFailed {
                    Label("Download couldn’t be verified or completed. Try again.", systemImage: "exclamationmark.circle")
                        .ipaFont(.subheadline).foregroundStyle(.secondary)
                }
                Button { confirmingDownload = true } label: {
                    Label("Download Build \(build)", systemImage: "arrow.down.to.line")
                        .ipaFont(.subheadline, weight: .semibold)
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .disabled(work != nil)
                Text(ByteCountFormatter.string(fromByteCount: package.size, countStyle: .file))
                    .ipaFont(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Link(destination: release.page) {
                Label("Release Notes on GitHub", systemImage: "arrow.up.right")
                    .ipaFont(.subheadline, weight: .semibold)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(IPAStyle.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private func check() {
        guard work == nil else { return }
        clearDownloadedFile()
        checking = true
        checkMessage = nil
        release = nil
        work = Task {
            defer { checking = false; work = nil }
            do {
                guard let latest = try await IPADistribution.latestRelease() else {
                    checkMessage = "No public release is available yet."
                    return
                }
                try Task.checkCancellation()
                if let installedBuild, let build = latest.build, build < installedBuild {
                    checkMessage = "No newer build has been published."
                    return
                }
                release = latest
                if let installedBuild, let build = latest.build, build > installedBuild {
                    if latest.package == nil {
                        checkMessage = "The latest build is listed. Its download isn’t available yet."
                    } else {
                        confirmingDownload = true
                    }
                }
            } catch {
                if !Task.isCancelled {
                    checkMessage = "Couldn’t check for updates. Check your connection and try again."
                }
            }
        }
    }

    private func download(_ package: IPADistribution.Release.Asset, build: Int) {
        guard work == nil else { return }
        let downloadID = UUID()
        activeDownloadID = downloadID
        downloadFailed = false
        progress = 0
        work = Task {
            defer { progress = nil; activeDownloadID = nil; work = nil }
            do {
                let file = try await IPADistribution.download(package, build: build) { fraction in
                    Task { @MainActor in
                        if activeDownloadID == downloadID, let current = progress {
                            progress = max(current, fraction)
                        }
                    }
                }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                } else {
                    downloadedFile = file
                }
            } catch {
                downloadFailed = !Task.isCancelled
            }
        }
    }

    private func clearDownloadedFile() {
        if let downloadedFile {
            try? FileManager.default.removeItem(at: downloadedFile.deletingLastPathComponent())
            self.downloadedFile = nil
        }
    }
}
