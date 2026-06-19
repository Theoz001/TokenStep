import AppKit
import Foundation

struct AvailableUpdate: Identifiable, Equatable {
    var id: String { version }
    var version: String
    var tagName: String
    var title: String
    var notes: String
    var pageURL: URL
    var assetURL: URL
    var assetName: String
    var assetSize: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(assetSize), countStyle: .file)
    }

    var noteLines: [String] {
        let cleaned = notes
            .split(separator: "\n")
            .map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: "-• ").union(.whitespacesAndNewlines))
            }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("sha256") }
        return Array(cleaned.prefix(upTo: min(4, cleaned.count))).map { String($0) }
    }
}

enum UpdateCheckResult {
    case upToDate
    case available(AvailableUpdate)
}

enum UpdateService {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Backtthefuture/TokenStep/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func checkForUpdates(currentVersion: String = Self.currentVersion) async throws -> UpdateCheckResult {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TokenStep/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.checkFailed
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { return .upToDate }
        let version = release.tagName.strippingVersionPrefix
        guard Version(version) > Version(currentVersion) else { return .upToDate }
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let pageURL = URL(string: release.htmlURL),
              let assetURL = URL(string: asset.downloadURL)
        else {
            throw UpdateError.missingDMG
        }

        return .available(
            AvailableUpdate(
                version: version,
                tagName: release.tagName,
                title: release.name ?? "TokenStep \(version)",
                notes: release.body ?? "",
                pageURL: pageURL,
                assetURL: assetURL,
                assetName: asset.name,
                assetSize: asset.size
            )
        )
    }

    static func downloadAndOpen(_ update: AvailableUpdate, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let downloader = UpdateDownloader(progress: progress)
        let temporaryURL = try await downloader.download(from: update.assetURL)
        let destination = downloadsDirectory.appendingPathComponent(update.assetName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        _ = await MainActor.run {
            NSWorkspace.shared.open(destination)
        }
        return destination
    }

    private static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}

enum UpdateError: LocalizedError {
    case checkFailed
    case missingDMG
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .checkFailed:
            return "检查更新失败，请稍后再试。"
        case .missingDMG:
            return "新版本没有可下载的 DMG。"
        case .downloadFailed:
            return "下载更新失败，请稍后再试。"
        }
    }
}

private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    private let progress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(progress: @escaping @MainActor (Double) -> Void) {
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            progress(min(max(value, 0), 1))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dmg")
        do {
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            continuation?.resume(returning: temporaryURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
        session.invalidateAndCancel()
    }
}

private struct GitHubRelease: Decodable {
    var tagName: String
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var htmlURL: String
    var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    var name: String
    var downloadURL: String
    var size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
    }
}

private struct Version: Comparable {
    var parts: [Int]

    init(_ value: String) {
        parts = value.strippingVersionPrefix
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

private extension String {
    var strippingVersionPrefix: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
    }
}
