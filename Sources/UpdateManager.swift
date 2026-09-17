import AppKit
import Combine
import Foundation

struct AvailableUpdate: Equatable {
    let version: AppVersion
    let assetURL: URL
    let assetDigest: String
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(AvailableUpdate)
    case downloading(Double)
    case validating
    case installing
    case failed(String)
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var noticeKey: String?
    var notice: String? {
        noticeKey.map { L10n.string($0, language: L10n.currentLanguage) }
    }

    private let session: URLSession
    private let fileManager: FileManager
    private let currentVersion: AppVersion?
    private let currentBuild: String
    private var didPostponeAutomaticPrompt = false
    private var isPresentingPrompt = false

    private static let releaseAPIURL = URL(string: "https://api.github.com/repos/allanzhang/MDReview/releases/latest")!
    private static let expectedBundleIdentifier = "com.doubleeagle.MDReview"
    private static let requestTimeout: TimeInterval = 20

    init(bundle: Bundle = .main, session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
        currentVersion = AppVersion(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var currentShortVersion: String {
        currentVersion?.description ?? "—"
    }

    var currentBuildNumber: String {
        currentBuild
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .validating, .installing:
            return true
        case .idle, .upToDate, .updateAvailable, .failed:
            return false
        }
    }

    var statusText: String {
        switch status {
        case .idle:
            return L10n.string("Automatic update checks are enabled.", language: L10n.currentLanguage)
        case .checking:
            return L10n.string("Checking for updates…", language: L10n.currentLanguage)
        case .upToDate:
            return L10n.string("MDReview is up to date.", language: L10n.currentLanguage)
        case .updateAvailable(let update):
            return L10n.format("Version %@ is available.", language: L10n.currentLanguage, update.version.description)
        case .downloading(let progress):
            return L10n.format("Downloading update… %lld%%", language: L10n.currentLanguage, Int((progress * 100).rounded()))
        case .validating:
            return L10n.string("Validating update…", language: L10n.currentLanguage)
        case .installing:
            return L10n.string("Installing update and restarting…", language: L10n.currentLanguage)
        case .failed(let message):
            return message
        }
    }

    func checkForUpdates(manual: Bool) async {
        if manual, case .updateAvailable(let update) = status {
            noticeKey = nil
            presentPrompt(for: update)
            return
        }

        guard !isBusy else {
            if manual {
                noticeKey = "An update check is already in progress."
            }
            return
        }

        noticeKey = nil
        status = .checking

        do {
            let release = try await fetchLatestRelease()
            let update = try makeAvailableUpdate(from: release)

            guard let update else {
                status = .upToDate
                return
            }

            status = .updateAvailable(update)
            if manual || !didPostponeAutomaticPrompt {
                presentPrompt(for: update)
            }
        } catch {
            if manual {
                status = .failed(error.localizedDescription)
            } else {
                status = .idle
            }
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releaseAPIURL)
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MDReview", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.invalidRelease
        }
    }

    private func makeAvailableUpdate(from release: GitHubRelease) throws -> AvailableUpdate? {
        guard !release.draft, !release.prerelease else { return nil }

        var releaseVersion = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if releaseVersion.first == "v" || releaseVersion.first == "V" {
            releaseVersion.removeFirst()
        }

        guard let version = AppVersion(releaseVersion), let currentVersion else {
            throw UpdateError.invalidVersion
        }
        guard version > currentVersion else { return nil }

        let expectedAssetName = "MDReview-\(releaseVersion).zip"
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }),
              asset.browserDownloadURL.scheme == "https" else {
            throw UpdateError.missingAsset(expectedAssetName)
        }

        guard let digest = asset.digest?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isValidSHA256Digest(digest) else {
            throw UpdateError.invalidDigest
        }

        return AvailableUpdate(version: version, assetURL: asset.browserDownloadURL, assetDigest: digest.lowercased())
    }

    private func presentPrompt(for update: AvailableUpdate) {
        guard !isPresentingPrompt else { return }
        isPresentingPrompt = true
        defer { isPresentingPrompt = false }

        let alert = NSAlert()
        let language = L10n.currentLanguage
        alert.messageText = L10n.string("A new version of MDReview is available.", language: language)
        alert.informativeText = L10n.format("You have version %@. Version %@ is available.",
                                            language: language,
                                            currentShortVersion,
                                            update.version.description)
        alert.addButton(withTitle: L10n.string("Update Now", language: language))
        alert.addButton(withTitle: L10n.string("Later", language: language))

        if alert.runModal() == .alertFirstButtonReturn {
            AboutWindowController.shared.show()
            Task { @MainActor in
                await self.downloadAndInstall(update)
            }
        } else {
            didPostponeAutomaticPrompt = true
        }
    }

    private func downloadAndInstall(_ update: AvailableUpdate) async {
        var updateDirectory: URL?

        do {
            let directory = try makeUpdateDirectory()
            updateDirectory = directory

            let archiveURL = directory.appendingPathComponent("MDReview-\(update.version).zip")
            status = .downloading(0)
            try await downloadAsset(from: update.assetURL, to: archiveURL)

            status = .validating
            try verifyDigest(of: archiveURL, expectedDigest: update.assetDigest)

            let extractedDirectory = directory.appendingPathComponent("Extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
            try await extractArchive(archiveURL, into: extractedDirectory)

            let newBundleURL = extractedDirectory.appendingPathComponent("MDReview.app", isDirectory: true)
            try validateBundle(at: newBundleURL)

            status = .installing
            try await installBundle(from: newBundleURL, updateDirectory: directory)
        } catch {
            if let updateDirectory {
                try? fileManager.removeItem(at: updateDirectory)
            }
            status = .failed(error.localizedDescription)
        }
    }

    private func makeUpdateDirectory() throws -> URL {
        let baseDirectory: URL
        if let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            baseDirectory = cachesDirectory.appendingPathComponent("MDReviewUpdates", isDirectory: true)
        } else {
            baseDirectory = fileManager.temporaryDirectory.appendingPathComponent("MDReviewUpdates", isDirectory: true)
        }

        let updateDirectory = baseDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
        return updateDirectory
    }

    private func downloadAsset(from sourceURL: URL, to destinationURL: URL) async throws {
        let delegate = DownloadFileDelegate(
            destinationURL: destinationURL,
            fileManager: fileManager,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.status = .downloading(progress)
                }
            }
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        let downloadSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { downloadSession.invalidateAndCancel() }

        let request = URLRequest(url: sourceURL, timeoutInterval: Self.requestTimeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                delegate.attach(continuation: continuation)
                let task = downloadSession.downloadTask(with: request)
                delegate.attach(task: task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func verifyDigest(of fileURL: URL, expectedDigest: String) throws {
        let actualDigest = try UpdateIntegrity.sha256Hex(ofFileAt: fileURL)
        guard actualDigest == expectedDigest.replacingOccurrences(of: "sha256:", with: "").lowercased() else {
            throw UpdateError.digestMismatch
        }
    }

    private func extractArchive(_ archiveURL: URL, into destinationURL: URL) async throws {
        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, destinationURL.path]
        )
        guard result.status == 0 else {
            throw UpdateError.extractionFailed(result.standardError)
        }
    }

    private func validateBundle(at bundleURL: URL) throws {
        guard let currentVersion,
              let bundle = Bundle(url: bundleURL),
              bundle.bundleIdentifier == Self.expectedBundleIdentifier,
              let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let newVersion = AppVersion(shortVersion),
              newVersion > currentVersion else {
            throw UpdateError.invalidBundle
        }
    }

    private func installBundle(from newBundleURL: URL, updateDirectory: URL) async throws {
        let currentBundleURL = Bundle.main.bundleURL
        guard currentBundleURL.pathExtension.lowercased() == "app" else {
            throw UpdateError.invalidInstallLocation
        }

        let destinationDirectory = currentBundleURL.deletingLastPathComponent()
        try verifyWritable(destinationDirectory)

        let backupURL = destinationDirectory.appendingPathComponent(".MDReview-backup-\(UUID().uuidString)", isDirectory: true)
        let helperURL = updateDirectory.appendingPathComponent("install-update.sh")
        let readyURL = updateDirectory.appendingPathComponent("helper-ready")
        try Self.helperScript.write(to: helperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            helperURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            currentBundleURL.path,
            newBundleURL.path,
            backupURL.path,
            readyURL.path,
            updateDirectory.path
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice

        do {
            try helper.run()
        } catch {
            throw UpdateError.helperFailed
        }

        let deadline = Date().addingTimeInterval(2)
        while !fileManager.fileExists(atPath: readyURL.path) {
            guard helper.isRunning else {
                throw UpdateError.helperFailed
            }
            if Date() >= deadline {
                helper.terminate()
                throw UpdateError.helperFailed
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        NSApp.terminate(nil)
    }

    private func verifyWritable(_ directoryURL: URL) throws {
        let probeURL = directoryURL.appendingPathComponent(".mdreview-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probeURL)
            try fileManager.removeItem(at: probeURL)
        } catch {
            throw UpdateError.installLocationNotWritable
        }
    }

    private func runProcess(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw UpdateError.processLaunchFailed
            }

            process.waitUntilExit()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let standardError = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ProcessResult(status: process.terminationStatus, standardError: standardError)
        }.value
    }

    private static func isValidSHA256Digest(_ digest: String) -> Bool {
        let value = digest.lowercased()
        guard value.hasPrefix("sha256:") else { return false }
        let hex = String(value.dropFirst("sha256:".count))
        return hex.count == 64 && hex.allSatisfy { character in
            character >= "0" && character <= "9" || character >= "a" && character <= "f"
        }
    }

    private static let helperScript = """
    #!/bin/sh
    set -u

    [ "$#" -eq 6 ] || exit 14

    pid="$1"
    current="$2"
    new="$3"
    backup="$4"
    ready="$5"
    temp="$6"

    : > "$ready" || exit 13

    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
    done

    if ! mv "$current" "$backup"; then
        /usr/bin/open "$current" >/dev/null 2>&1 || true
        exit 10
    fi

    if ! /usr/bin/ditto "$new" "$current"; then
        rm -rf "$current"
        if mv "$backup" "$current"; then
            /usr/bin/open "$current" >/dev/null 2>&1 || true
        fi
        exit 11
    fi

    if ! /usr/bin/open "$current" >/dev/null 2>&1; then
        rm -rf "$current"
        if mv "$backup" "$current"; then
            /usr/bin/open "$current" >/dev/null 2>&1 || true
        fi
        exit 12
    fi

    rm -rf "$backup"
    rm -rf "$temp"
    exit 0
    """
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

private struct ProcessResult: Sendable {
    let status: Int32
    let standardError: String
}

private final class DownloadFileDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let fileManager: FileManager
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var isFinished = false

    init(
        destinationURL: URL,
        fileManager: FileManager,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.destinationURL = destinationURL
        self.fileManager = fileManager
        self.onProgress = onProgress
    }

    func attach(task newTask: URLSessionDownloadTask) {
        lock.lock()
        task = newTask
        lock.unlock()
    }

    func attach(continuation newContinuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        continuation = newContinuation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let taskToCancel = task
        lock.unlock()
        taskToCancel?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                finish(.failure(UpdateError.downloadFailed))
                return
            }

            try? fileManager.removeItem(at: destinationURL)
            try fileManager.moveItem(at: location, to: destinationURL)
            finish(.success(destinationURL))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.failure(UpdateError.downloadFailed))
        }
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidRelease
    case invalidVersion
    case missingAsset(String)
    case invalidDigest
    case downloadFailed
    case digestMismatch
    case extractionFailed(String)
    case invalidBundle
    case invalidInstallLocation
    case installLocationNotWritable
    case helperFailed
    case processLaunchFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.string("The update server returned an invalid response.", language: L10n.currentLanguage)
        case .httpStatus(let statusCode):
            return L10n.format("The update server returned HTTP %lld. Please try again later.", language: L10n.currentLanguage, statusCode)
        case .invalidRelease:
            return L10n.string("The latest release could not be read. Please try again later.", language: L10n.currentLanguage)
        case .invalidVersion:
            return L10n.string("The latest release has an invalid version tag.", language: L10n.currentLanguage)
        case .missingAsset(let name):
            return L10n.format("The release does not contain the expected update asset: %@.", language: L10n.currentLanguage, name)
        case .invalidDigest:
            return L10n.string("The release does not provide a valid SHA256 digest.", language: L10n.currentLanguage)
        case .downloadFailed:
            return L10n.string("The update download failed. Please try again.", language: L10n.currentLanguage)
        case .digestMismatch:
            return L10n.string("The downloaded update failed SHA256 verification.", language: L10n.currentLanguage)
        case .extractionFailed(let message):
            return message.isEmpty
                ? L10n.string("The downloaded update could not be extracted.", language: L10n.currentLanguage)
                : L10n.format("The update could not be extracted: %@", language: L10n.currentLanguage, message)
        case .invalidBundle:
            return L10n.string("The downloaded app failed bundle identifier or version validation.", language: L10n.currentLanguage)
        case .invalidInstallLocation:
            return L10n.string("MDReview is running from an unsupported location and cannot be updated in place.", language: L10n.currentLanguage)
        case .installLocationNotWritable:
            return L10n.string("The MDReview application folder is not writable, so the update cannot be installed.", language: L10n.currentLanguage)
        case .helperFailed:
            return L10n.string("The update helper could not be started. MDReview was not changed.", language: L10n.currentLanguage)
        case .processLaunchFailed:
            return L10n.string("A required system tool could not be started.", language: L10n.currentLanguage)
        }
    }
}
