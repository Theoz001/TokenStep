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

    static func downloadAndInstall(
        _ update: AvailableUpdate,
        requireVerified: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let downloader = UpdateDownloader(progress: progress)
        let temporaryURL = try await downloader.download(from: update.assetURL)
        try FileManager.default.createDirectory(at: AppPaths.updates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)

        let destination = AppPaths.updates.appendingPathComponent(update.assetName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        try preflightDMG(destination, requireVerified: requireVerified)
        try launchInstaller(for: destination, requireVerified: requireVerified)
        return destination
    }

    private static func preflightDMG(_ dmgURL: URL, requireVerified: Bool) throws {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstep-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer {
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        try runProcess("/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-quiet", "-mountpoint", mountPoint.path, dmgURL.path])
        let appURL = try findTokenStepApp(in: mountPoint)
        guard !requireVerified || isVerifiedApp(appURL) else {
            throw UpdateError.verificationFailed
        }
    }

    private static func findTokenStepApp(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw UpdateError.installFailed
        }

        for case let url as URL in enumerator where url.lastPathComponent == "TokenStep.app" {
            return url
        }
        throw UpdateError.installFailed
    }

    private static func isVerifiedApp(_ appURL: URL) -> Bool {
        (try? runProcess("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", appURL.path])) != nil
            && (try? runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])) != nil
    }

    private static func launchInstaller(for dmgURL: URL, requireVerified: Bool) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstep-install-\(UUID().uuidString)")
            .appendingPathExtension("sh")
        let logURL = AppPaths.logs.appendingPathComponent("update-install-\(Int(Date().timeIntervalSince1970)).log")
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let script = installerScript(
            dmgPath: dmgURL.path,
            currentPID: currentPID,
            logPath: logURL.path,
            requireVerified: requireVerified,
            scriptPath: scriptURL.path
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed
        }
    }

    private static func installerScript(
        dmgPath: String,
        currentPID: Int32,
        logPath: String,
        requireVerified: Bool,
        scriptPath: String
    ) -> String {
        """
        #!/bin/bash
        set -euo pipefail

        DMG=\(shellQuote(dmgPath))
        DEST="/Applications/TokenStep.app"
        APP_NAME="TokenStep.app"
        CURRENT_PID="\(currentPID)"
        LOG=\(shellQuote(logPath))
        REQUIRE_VERIFIED="\(requireVerified ? "1" : "0")"
        SCRIPT_PATH=\(shellQuote(scriptPath))
        MOUNT_POINT=""
        BACKUP=""

        mkdir -p "$(dirname "$LOG")"
        exec >>"$LOG" 2>&1
        echo "TokenStep update installer started at $(date)"

        cleanup() {
          if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
            /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
            /bin/rmdir "$MOUNT_POINT" 2>/dev/null || true
          fi
          /bin/rm -f "$SCRIPT_PATH" 2>/dev/null || true
        }
        finish() {
          STATUS=$?
          if [ "$STATUS" -ne 0 ]; then
            echo "TokenStep update installer failed with status $STATUS"
            if [ -n "$BACKUP" ] && [ -d "$BACKUP" ] && [ ! -d "$DEST" ]; then
              /bin/mv "$BACKUP" "$DEST" || true
            fi
            /usr/bin/osascript -e 'display notification "请手动把 DMG 里的 TokenStep 拖到 Applications。" with title "TokenStep 自动更新失败"' || true
          fi
          cleanup
          exit "$STATUS"
        }
        trap finish EXIT

        while /bin/kill -0 "$CURRENT_PID" 2>/dev/null; do
          /bin/sleep 0.2
        done

        MOUNT_POINT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenstep-update.XXXXXX")"
        /usr/bin/hdiutil attach -nobrowse -quiet -mountpoint "$MOUNT_POINT" "$DMG"

        SRC="$(/usr/bin/find "$MOUNT_POINT" -name "$APP_NAME" -type d -print -quit)"
        if [ -z "$SRC" ]; then
          echo "TokenStep.app not found in DMG"
          exit 1
        fi

        if [ "$REQUIRE_VERIFIED" = "1" ]; then
          /usr/sbin/spctl --assess --type execute "$SRC"
          /usr/bin/codesign --verify --deep --strict "$SRC"
        fi

        BACKUP="/Applications/TokenStep.app.previous.$(/bin/date +%s)"
        if [ -d "$DEST" ]; then
          /bin/mv "$DEST" "$BACKUP"
        fi

        if ! /usr/bin/ditto "$SRC" "$DEST"; then
          /bin/rm -rf "$DEST"
          if [ -d "$BACKUP" ]; then
            /bin/mv "$BACKUP" "$DEST"
          fi
          echo "Failed to copy TokenStep.app into /Applications"
          exit 1
        fi

        if [ -d "$BACKUP" ]; then
          /bin/rm -rf "$BACKUP"
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        /usr/bin/open "$DEST"
        echo "TokenStep update installer finished at $(date)"
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    @discardableResult
    private static func runProcess(_ executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.installFailed
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}

enum UpdateError: LocalizedError {
    case checkFailed
    case missingDMG
    case downloadFailed
    case verificationFailed
    case installFailed

    var errorDescription: String? {
        switch self {
        case .checkFailed:
            return "检查更新失败，请稍后再试。"
        case .missingDMG:
            return "新版本没有可下载的 DMG。"
        case .downloadFailed:
            return "下载更新失败，请稍后再试。"
        case .verificationFailed:
            return "新版本未通过签名或公证验证，已停止安装。"
        case .installFailed:
            return "自动安装失败，请稍后重试，或手动把 TokenStep 拖到 Applications。"
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
