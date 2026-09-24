import Foundation

private var failures: [String] = []
private var passed = 0

/// 断言一条契约。失败时记录原因，不立即中断，便于一次看到所有违约项。
func check(_ name: String, _ condition: @autoclosure () -> Bool, _ reason: String) {
    if condition() {
        passed += 1
        print("ok - \(name)")
    } else {
        failures.append("\(name): \(reason)")
        print("FAIL - \(name): \(reason)")
    }
}

/// 汇总结束。有失败时以非零退出码终止进程。
func finishChecks() {
    if !failures.isEmpty {
        fputs("\(failures.count) check(s) failed\n", stderr)
        exit(1)
    }
    print("ok - \(passed) checks passed")
}
