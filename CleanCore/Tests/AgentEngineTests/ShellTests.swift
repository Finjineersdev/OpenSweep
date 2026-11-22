// SPDX-License-Identifier: MIT

import XCTest
import CleanCore

final class ShellTests: XCTestCase {
    /// A tool that fills stderr before writing stdout must not stall until
    /// the timeout: both pipes are drained at once.
    func testABusyStderrDoesNotStall() async {
        let start = Date()
        let out = await Shell.run("/bin/sh", ["-c", "head -c 200000 /dev/zero >&2; echo ok"], timeout: 20)
        XCTAssertEqual(out.stdout, "ok\n")
        XCTAssertEqual(out.stderr.utf8.count, 200_000)
        XCTAssertTrue(out.ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
