import CryptoKit
import Foundation

@main
struct UpdateIntegrityTests {
    static func main() {
        do {
            try run()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("mdreview-integrity-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let fixtureURL = directory.appendingPathComponent("fixture.bin")
        let payload = Data((0..<(3 * 1024 * 1024) + 271).map { UInt8($0 % 251) })
        try payload.write(to: fixtureURL)

        let wholeDataDigest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        let fileDigest = try UpdateIntegrity.sha256Hex(ofFileAt: fixtureURL)

        expect(fileDigest == wholeDataDigest, "streaming digest matches whole-file digest")

        print("ok - update integrity tests")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
