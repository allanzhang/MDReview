import Foundation

struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        guard !value.isEmpty else { return nil }

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)

        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let component = Int(part) else {
                return nil
            }
            parsed.append(component)
        }

        components = parsed
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return (0..<count).allSatisfy { index in
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            return left == right
        }
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }
}
