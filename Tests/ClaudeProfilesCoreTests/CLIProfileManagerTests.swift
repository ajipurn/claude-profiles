import XCTest
@testable import ClaudeProfilesCore

final class CLIProfileManagerTests: XCTestCase {
    let fm = FileManager.default
    var home: URL!
    var cli: CLIProfileManager!

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("claude-cli-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        cli = CLIProfileManager(home: home)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    func testFreshStateIsDefault() {
        XCTAssertFalse(cli.isSetUp)
        XCTAssertEqual(cli.profiles(), [])
        XCTAssertNil(cli.activeProfile())
    }

    func testInstallShimIsIdempotentAndExecutable() throws {
        try cli.installShim()
        try cli.installShim()
        XCTAssertTrue(cli.isSetUp)
        XCTAssertTrue(fm.isExecutableFile(atPath: cli.shim.path))
        let script = try String(contentsOf: cli.shim, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("CLAUDE_CONFIG_DIR"))
    }

    func testCreateListSwitchDelete() throws {
        try cli.createProfile(name: "work")
        try cli.createProfile(name: "personal")
        XCTAssertEqual(cli.profiles(), ["personal", "work"])

        try cli.setActive("work")
        XCTAssertEqual(cli.activeProfile(), "work")
        try cli.setActive(nil)
        XCTAssertNil(cli.activeProfile())

        // Deleting the active profile falls back to the default account.
        try cli.setActive("personal")
        try cli.deleteProfile(name: "personal")
        XCTAssertNil(cli.activeProfile())
        XCTAssertEqual(cli.profiles(), ["work"])
    }

    func testRenameMovesDirAndFollowsActive() throws {
        try cli.createProfile(name: "old")
        try cli.setActive("old")
        XCTAssertEqual(try cli.renameProfile("old", to: "new"), "new")
        XCTAssertEqual(cli.profiles(), ["new"])
        XCTAssertEqual(cli.activeProfile(), "new")
        XCTAssertThrowsError(try cli.renameProfile("ghost", to: "x"))
        try cli.createProfile(name: "other")
        XCTAssertThrowsError(try cli.renameProfile("new", to: "other"))
    }

    func testRejectsBadNamesAndDuplicates() throws {
        try cli.createProfile(name: "work")
        XCTAssertThrowsError(try cli.createProfile(name: "work"))
        XCTAssertThrowsError(try cli.createProfile(name: "!!!"))
        XCTAssertThrowsError(try cli.setActive("missing"))
        XCTAssertThrowsError(try cli.deleteProfile(name: "missing"))
    }

    func testHideDefaultIsUIOnlyAndReversible() throws {
        XCTAssertFalse(cli.defaultHidden)
        try cli.setDefaultHidden(true)
        XCTAssertTrue(cli.defaultHidden)
        XCTAssertNil(cli.activeProfile()) // selection untouched
        try cli.setDefaultHidden(false)
        XCTAssertFalse(cli.defaultHidden)
    }

    func testUnknownNameInActiveFileMeansDefault() throws {
        try cli.installShim()
        try "stale-profile\n".write(to: cli.cliDir.appendingPathComponent("active"),
                                    atomically: true, encoding: .utf8)
        XCTAssertNil(cli.activeProfile())
    }

    func testCLIDirHiddenFromDesktopProfiles() throws {
        try cli.createProfile(name: "work")
        let desktop = ProfileManager(home: home)
        try fm.createDirectory(at: desktop.profilesDir.appendingPathComponent("main"),
                               withIntermediateDirectories: true)
        XCTAssertEqual(desktop.profiles(), ["main"])
    }
}
