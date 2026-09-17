import Foundation

@main
struct DocStateFileMonitorTests {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("mdreview-file-monitor-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let fixtureURL = directory.appendingPathComponent("fixture.md")
        try "initial".write(to: fixtureURL, atomically: true, encoding: .utf8)

        let suiteName = "mdreview.language-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = DocState(defaults: defaults)
        state.open(fixtureURL)
        try await waitUntil("document opens") { state.url == fixtureURL }

        let originalURL = state.url
        let originalText = state.rawText
        let originalSourceMode = state.showSource
        state.setLanguage(.chinese)
        guard state.url == originalURL,
              state.rawText == originalText,
              state.showSource == originalSourceMode,
              state.language == .chinese else {
            throw TestError.stateChanged
        }
        state.setLanguage(.chinese)

        try "first change".write(to: fixtureURL, atomically: true, encoding: .utf8)
        try await waitUntil("first atomic save marks the file as updated") { state.hasPendingFileUpdate }
        state.clearPendingFileUpdate()

        try "second change".write(to: fixtureURL, atomically: true, encoding: .utf8)
        try await waitUntil("second atomic save marks the file as updated") { state.hasPendingFileUpdate }

        print("ok - file monitor survives atomic replacement")
    }

    @MainActor
    private static func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw TestError.timeout(description)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private enum TestError: LocalizedError {
        case timeout(String)
        case stateChanged

        var errorDescription: String? {
            switch self {
            case .timeout(let description):
                return "timed out waiting for \(description)"
            case .stateChanged:
                return "language change modified document state"
            }
        }
    }
}
