import Foundation

@main
struct UpdateVersionTests {
    static func main() {
        expect(AppVersion("v1.4.2") == AppVersion("1.4.2"), "leading v is accepted")
        expect(AppVersion("1.4") == AppVersion("1.4.0"), "missing components compare as zero")
        expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!, "components compare numerically")
        expect(AppVersion("2.0")! > AppVersion("1.99.99")!, "major version dominates")
        expect(AppVersion("1.4.2")! < AppVersion("1.4.3")!, "patch version compares")

        expect(AppVersion("") == nil, "empty version is rejected")
        expect(AppVersion("v") == nil, "bare v is rejected")
        expect(AppVersion("1.4.2-beta") == nil, "prerelease suffix is rejected")
        expect(AppVersion("1..2") == nil, "empty component is rejected")
        expect(AppVersion("1.a.2") == nil, "non-numeric component is rejected")

        print("ok - update version tests")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
