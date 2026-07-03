import XCTest
@testable import ClaudeProfilesCore

final class ProfileManagerTests: XCTestCase {
    let fm = FileManager.default
    var home: URL!
    var pm: ProfileManager!

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("claude-profiles-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        pm = ProfileManager(home: home)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    // MARK: - Helpers

    func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func makeRealClaudeDir() throws {
        try write("cookie-data", to: pm.claudeDir.appendingPathComponent("Cookies"))
    }

    func itemType(_ url: URL) -> FileAttributeType? {
        (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    func isSymlink(_ url: URL) -> Bool { itemType(url) == .typeSymbolicLink }
    func isRealDir(_ url: URL) -> Bool { itemType(url) == .typeDirectory }

    func profile(_ name: String) -> URL { pm.profilesDir.appendingPathComponent(name) }

    // MARK: - Sanitize

    func testSanitize() {
        XCTAssertEqual(ProfileManager.sanitize("My Profile!"), "MyProfile")
        XCTAssertEqual(ProfileManager.sanitize("work-2_a"), "work-2_a")
        XCTAssertEqual(ProfileManager.sanitize("user@example.com"), "user@example.com")
        XCTAssertNil(ProfileManager.sanitize(""))
        XCTAssertNil(ProfileManager.sanitize("💥 ééé"))
    }

    // MARK: - Migration

    func testMigrationMovesRealDirectoryAndSymlinks() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")

        XCTAssertTrue(isSymlink(pm.claudeDir))
        XCTAssertEqual(pm.activeProfile(), "main")
        XCTAssertEqual(
            try String(contentsOf: profile("main").appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
        // Readable through the symlink too.
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
    }

    func testMigrationWithMissingClaudeDirCreatesEmptyProfile() throws {
        try pm.migrate(name: "main")
        XCTAssertTrue(isSymlink(pm.claudeDir))
        XCTAssertTrue(isRealDir(profile("main")))
        XCTAssertEqual(pm.activeProfile(), "main")
    }

    func testMigrationRejectsExistingProfileName() throws {
        try fm.createDirectory(at: profile("main"), withIntermediateDirectories: true)
        try makeRealClaudeDir()

        XCTAssertThrowsError(try pm.migrate(name: "main")) {
            XCTAssertEqual($0 as? ProfileError, .profileExists("main"))
        }
        // Untouched.
        XCTAssertTrue(isRealDir(pm.claudeDir))
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
    }

    func testMigrationRejectsInvalidName() throws {
        try makeRealClaudeDir()
        XCTAssertThrowsError(try pm.migrate(name: "!!!")) {
            XCTAssertEqual($0 as? ProfileError, .invalidName)
        }
        XCTAssertTrue(isRealDir(pm.claudeDir))
    }

    // MARK: - Switching

    func testSwitchRepointsSymlink() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")

        try pm.switchTo(name: "work")
        XCTAssertEqual(pm.activeProfile(), "work")

        try pm.switchTo(name: "main")
        XCTAssertEqual(pm.activeProfile(), "main")
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
    }

    func testSwitchNeverClobbersRealDirectory() throws {
        try makeRealClaudeDir()
        try fm.createDirectory(at: profile("work"), withIntermediateDirectories: true)

        XCTAssertThrowsError(try pm.switchTo(name: "work")) {
            XCTAssertEqual($0 as? ProfileError, .refusedToClobber(pm.claudeDir.path))
        }
        XCTAssertTrue(isRealDir(pm.claudeDir))
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
    }

    func testSwitchToMissingProfileThrows() throws {
        try pm.migrate(name: "main")
        XCTAssertThrowsError(try pm.switchTo(name: "ghost")) {
            XCTAssertEqual($0 as? ProfileError, .profileNotFound("ghost"))
        }
        XCTAssertEqual(pm.activeProfile(), "main")
    }

    func testSwitchFixesBrokenSymlink() throws {
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")
        try pm.switchTo(name: "work")

        try fm.removeItem(at: profile("work")) // symlink now dangling

        guard case .symlink(_, false) = pm.claudeDirState() else {
            return XCTFail("expected broken symlink, got \(pm.claudeDirState())")
        }
        XCTAssertNil(pm.activeProfile())

        try pm.switchTo(name: "main")
        XCTAssertEqual(pm.activeProfile(), "main")
    }

    // MARK: - Listing

    func testProfilesSkipsUnderscoreAndHiddenDirs() throws {
        try fm.createDirectory(at: profile("alpha"), withIntermediateDirectories: true)
        try fm.createDirectory(at: profile("_shared-sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: profile(".hidden"), withIntermediateDirectories: true)
        try write("x", to: profile("not-a-dir.txt"))

        XCTAssertEqual(pm.profiles(), ["alpha"])
    }

    // MARK: - New profile + shared trees

    func testCreateProfilePrelinksSharedTrees() throws {
        for tree in ProfileManager.sessionTrees {
            try fm.createDirectory(at: pm.sharedDir.appendingPathComponent(tree), withIntermediateDirectories: true)
        }
        try pm.createProfile(name: "fresh")

        for tree in ProfileManager.sessionTrees {
            let link = profile("fresh").appendingPathComponent(tree)
            XCTAssertTrue(isSymlink(link), "\(tree) should be pre-linked")
            XCTAssertEqual(
                try fm.destinationOfSymbolicLink(atPath: link.path),
                pm.sharedDir.appendingPathComponent(tree).path
            )
        }
    }

    func testCreateProfileRejectsCollision() throws {
        try pm.createProfile(name: "dup")
        XCTAssertThrowsError(try pm.createProfile(name: "dup")) {
            XCTAssertEqual($0 as? ProfileError, .profileExists("dup"))
        }
    }

    // MARK: - Rename / delete

    func testRenameInactiveProfile() throws {
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")
        try write("x", to: profile("work").appendingPathComponent("marker.txt"))

        XCTAssertEqual(try pm.renameProfile("work", to: "office"), "office")
        XCTAssertTrue(fm.fileExists(atPath: profile("office").appendingPathComponent("marker.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: profile("work").path))
        XCTAssertEqual(pm.activeProfile(), "main") // untouched
    }

    func testRenameActiveProfileRepointsSymlink() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")
        try pm.renameProfile("main", to: "primary")
        XCTAssertEqual(pm.activeProfile(), "primary")
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
    }

    func testRenameRejectsCollisionAndUnknown() throws {
        try pm.createProfile(name: "a")
        try pm.createProfile(name: "b")
        XCTAssertThrowsError(try pm.renameProfile("a", to: "b")) {
            XCTAssertEqual($0 as? ProfileError, .profileExists("b"))
        }
        XCTAssertThrowsError(try pm.renameProfile("ghost", to: "x")) {
            XCTAssertEqual($0 as? ProfileError, .profileNotFound("ghost"))
        }
        XCTAssertEqual(try pm.renameProfile("a", to: "a"), "a") // no-op
    }

    func testDeleteProfileRefusesActiveDeletesInactive() throws {
        try pm.migrate(name: "main")
        try pm.createProfile(name: "gone")

        XCTAssertThrowsError(try pm.deleteProfile(name: "main")) {
            XCTAssertEqual($0 as? ProfileError, .profileIsActive("main"))
        }
        try pm.deleteProfile(name: "gone")
        XCTAssertEqual(pm.profiles(), ["main"])
        XCTAssertThrowsError(try pm.deleteProfile(name: "gone")) {
            XCTAssertEqual($0 as? ProfileError, .profileNotFound("gone"))
        }
    }

    func testDeleteProfileKeepsSharedHistory() throws {
        try seedTwoProfiles()
        try pm.enableSharedHistory()
        try pm.migrate(name: "main") // makes "main" active so a/b are deletable

        try pm.deleteProfile(name: "b")
        // b's sessions were merged into the shared master before; still there.
        let master = pm.sharedDir.appendingPathComponent("\(ProfileManager.sessionTrees[0])/acct1/org1")
        XCTAssertTrue(fm.fileExists(atPath: master.appendingPathComponent("local_3.json").path),
                      "deleting a profile must not touch shared history")
    }

    // MARK: - Shared history

    /// a: acct1/org1 with 2 files (master), b: acct2/org2 with 1 file + an agent tree.
    func seedTwoProfiles() throws {
        let code = ProfileManager.sessionTrees[0], agent = ProfileManager.sessionTrees[1]
        try write("a1", to: profile("a").appendingPathComponent("\(code)/acct1/org1/local_1.json"))
        try write("a2", to: profile("a").appendingPathComponent("\(code)/acct1/org1/local_2.json"))
        try write("b1", to: profile("b").appendingPathComponent("\(code)/acct2/org2/local_3.json"))
        try write("bx", to: profile("b").appendingPathComponent("\(agent)/acct2/org2/agent.json"))
    }

    func testEnableSharedHistoryMergesLinksAndBacksUp() throws {
        try seedTwoProfiles()
        let code = ProfileManager.sessionTrees[0], agent = ProfileManager.sessionTrees[1]

        let backup = try pm.enableSharedHistory()

        // Backup exists and holds the originals.
        let backupDir = try XCTUnwrap(backup)
        XCTAssertTrue(backupDir.lastPathComponent.hasPrefix("claude-session-backup-"))
        XCTAssertEqual(
            try String(contentsOf: backupDir.appendingPathComponent("b/\(code)/acct2/org2/local_3.json"), encoding: .utf8),
            "b1"
        )

        // Every profile tree is now a symlink into _shared-sessions (missing ones included).
        for profileName in ["a", "b"] {
            for tree in ProfileManager.sessionTrees {
                let link = profile(profileName).appendingPathComponent(tree)
                XCTAssertTrue(isSymlink(link), "\(profileName)/\(tree) should be a symlink")
                XCTAssertEqual(
                    try fm.destinationOfSymbolicLink(atPath: link.path),
                    pm.sharedDir.appendingPathComponent(tree).path
                )
            }
        }

        // Master org dir (acct1/org1, most files) got acct2/org2's file merged in;
        // acct2/org2 is now a symlink to the master.
        let sharedCode = pm.sharedDir.appendingPathComponent(code)
        let master = sharedCode.appendingPathComponent("acct1/org1")
        XCTAssertTrue(isRealDir(master))
        for f in ["local_1.json", "local_2.json", "local_3.json"] {
            XCTAssertTrue(fm.fileExists(atPath: master.appendingPathComponent(f).path), "\(f) missing in master")
        }
        let other = sharedCode.appendingPathComponent("acct2/org2")
        XCTAssertTrue(isSymlink(other))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: other.path), master.path)

        // All sessions visible through profile b's path (symlink chain).
        XCTAssertTrue(fm.fileExists(
            atPath: profile("b").appendingPathComponent("\(code)/acct2/org2/local_1.json").path
        ))

        // Single org dir in the agent tree: merged, no account-level linking needed.
        XCTAssertEqual(
            try String(contentsOf: pm.sharedDir.appendingPathComponent("\(agent)/acct2/org2/agent.json"), encoding: .utf8),
            "bx"
        )
        XCTAssertTrue(pm.sharedHistoryEnabled)
    }

    func testEnableSharedHistoryNeverOverwrites() throws {
        let code = ProfileManager.sessionTrees[0]
        try write("A-version", to: profile("a").appendingPathComponent("\(code)/acct/org/same.json"))
        try write("B-version", to: profile("b").appendingPathComponent("\(code)/acct/org/same.json"))

        let backup = try XCTUnwrap(try pm.enableSharedHistory())

        // First merge (a, alphabetical) wins; b's copy never overwrites — but survives in backup.
        XCTAssertEqual(
            try String(contentsOf: pm.sharedDir.appendingPathComponent("\(code)/acct/org/same.json"), encoding: .utf8),
            "A-version"
        )
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("b/\(code)/acct/org/same.json"), encoding: .utf8),
            "B-version"
        )
    }

    func testRerunLinksAccountThatLoggedInAfterEnable() throws {
        try seedTwoProfiles()
        try pm.enableSharedHistory()

        // A new account logs in on a fresh profile: Claude writes its org dir
        // through the profile symlink, i.e. straight into the shared tree.
        let code = ProfileManager.sessionTrees[0]
        try write("n1", to: pm.sharedDir.appendingPathComponent("\(code)/acct3/org3/local_9.json"))

        try pm.enableSharedHistory() // re-run on next profile switch

        let master = pm.sharedDir.appendingPathComponent("\(code)/acct1/org1")
        let newcomer = pm.sharedDir.appendingPathComponent("\(code)/acct3/org3")
        XCTAssertTrue(isSymlink(newcomer), "new account's org dir should be linked to master")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: newcomer.path), master.path)
        XCTAssertTrue(fm.fileExists(atPath: master.appendingPathComponent("local_9.json").path))
    }

    func testEnableSharedHistoryIsIdempotent() throws {
        try seedTwoProfiles()
        XCTAssertNotNil(try pm.enableSharedHistory())

        let secondBackup = try pm.enableSharedHistory(now: Date().addingTimeInterval(60))
        XCTAssertNil(secondBackup, "re-run must be a no-op")

        let backups = try fm.contentsOfDirectory(atPath: home.path)
            .filter { $0.hasPrefix("claude-session-backup-") }
        XCTAssertEqual(backups.count, 1)

        // Structure intact after re-run.
        let master = pm.sharedDir.appendingPathComponent("\(ProfileManager.sessionTrees[0])/acct1/org1")
        XCTAssertTrue(isRealDir(master))
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: master.path).sorted(),
            ["local_1.json", "local_2.json", "local_3.json"]
        )
    }
}
