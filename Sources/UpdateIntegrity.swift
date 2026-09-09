import CryptoKit
import Foundation

enum UpdateIntegrity {
    static func sha256Hex(ofFileAt fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
