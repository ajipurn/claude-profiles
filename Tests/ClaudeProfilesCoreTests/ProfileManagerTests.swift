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

    let code = ProfileManager.sessionTrees[0]
    let agent = ProfileManager.sessionTrees[1]

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
    func linkTarget(_ url: URL) -> String? { try? fm.destinationOfSymbolicLink(atPath: url.path) }

    func profile(_ name: String) -> URL { pm.profilesDir.appendingPathComponent(name) }

    /// Production org ids are uuids; orgIDs(of:) length-checks for 36 chars.
    func orgID(_ c: Character) -> String {
        let q = String(repeating: c, count: 4)
        return "\(q)\(q)-\(q)-\(q)-\(q)-\(q)\(q)\(q)"
    }

    func writeIDs(account: String, org: String, into dir: URL) throws {
        try write(#"{"ownerAccountId":"\#(account)"}"#, to: dir.appendingPathComponent("cowork-enabled-cli-ops.json"))
        try write(#"{"dxt:desk:\#(org)":1}"#, to: dir.appendingPathComponent("config.json"))
    }

    /// Cowork's mount check: openat2(RESOLVE_NO_SYMLINKS) — no component of
    /// the path below `root` may be a symlink. The active profile's session
    /// paths must always satisfy this or Cowork sessions cannot start.
    func assertNoSymlinkComponents(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let rootComps = home.standardizedFileURL.pathComponents
        var cur = home!
        for c in url.standardizedFileURL.pathComponents[rootComps.count...] {
            cur = cur.appendingPathComponent(c)
            XCTAssertFalse(isSymlink(cur), "\(cur.path) is a symlink — Cowork would refuse to mount",
                           file: file, line: line)
        }
    }

    // MARK: - Sanitize

    func testSanitize() {
        XCTAssertEqual(ProfileManager.sanitize("My Profile!"), "MyProfile")
        XCTAssertEqual(ProfileManager.sanitize("work-2_a"), "work-2_a")
        XCTAssertEqual(ProfileManager.sanitize("user@example.com"), "user@example.com")
        XCTAssertEqual(ProfileManager.sanitize("_cli"), "cli", "reserved prefix must be stripped")
        XCTAssertEqual(ProfileManager.sanitize(".hidden"), "hidden")
        XCTAssertNil(ProfileManager.sanitize(""))
        XCTAssertNil(ProfileManager.sanitize("..."))
        XCTAssertNil(ProfileManager.sanitize("💥 ééé"))
    }

    // MARK: - Setup (adoption)

    func testMigrateAdoptsClaudeDirInPlace() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")

        XCTAssertTrue(isRealDir(pm.claudeDir), "Claude must stay a real directory")
        XCTAssertEqual(pm.activeProfile(), "main")
        XCTAssertEqual(pm.claudeDirState(), .managed(active: "main"))
        XCTAssertFalse(fm.fileExists(atPath: profile("main").path),
                       "the active profile has no directory under Claude-Profiles")
        XCTAssertEqual(pm.profiles(), ["main"])
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
    }

    func testMigrateWithMissingClaudeDirCreatesIt() throws {
        try pm.migrate(name: "main")
        XCTAssertTrue(isRealDir(pm.claudeDir))
        XCTAssertEqual(pm.activeProfile(), "main")
    }

    func testMigrateGuards() throws {
        try makeRealClaudeDir()
        try fm.createDirectory(at: profile("dup"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try pm.migrate(name: "dup")) {
            XCTAssertEqual($0 as? ProfileError, .profileExists("dup"))
        }
        XCTAssertThrowsError(try pm.migrate(name: "!!!")) {
            XCTAssertEqual($0 as? ProfileError, .invalidName)
        }
        try pm.migrate(name: "main")
        XCTAssertThrowsError(try pm.migrate(name: "again")) {
            XCTAssertEqual($0 as? ProfileError, .nothingToMigrate)
        }
    }

    // MARK: - Switching

    func testSwitchSwapsDirectories() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")
        try write("work-data", to: profile("work").appendingPathComponent("Cookies"))

        try pm.switchTo(name: "work")
        XCTAssertEqual(pm.activeProfile(), "work")
        XCTAssertTrue(isRealDir(pm.claudeDir), "no symlink anywhere in the live path")
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "work-data"
        )
        XCTAssertEqual(
            try String(contentsOf: profile("main").appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data", "old profile parked in Claude-Profiles"
        )
        XCTAssertFalse(fm.fileExists(atPath: profile("work").path), "new profile's slot vacated")
        XCTAssertEqual(pm.profiles(), ["main", "work"])

        try pm.switchTo(name: "main")
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
    }

    func testSwitchNeverClobbersUnmanagedDirectory() throws {
        try makeRealClaudeDir() // real dir, never adopted
        try fm.createDirectory(at: profile("work"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try pm.switchTo(name: "work")) {
            XCTAssertEqual($0 as? ProfileError, .refusedToClobber(pm.claudeDir.path))
        }
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

    func testSwitchInstallsProfileWhenClaudeDirMissing() throws {
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")
        try fm.removeItem(at: pm.claudeDir)
        try pm.switchTo(name: "work")
        XCTAssertEqual(pm.activeProfile(), "work")
        XCTAssertTrue(isRealDir(pm.claudeDir))
    }

    func testSwitchReplacesDanglingLegacyLink() throws {
        try fm.createDirectory(at: profile("work"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: pm.claudeDir.path,
                                  withDestinationPath: profile("gone").path)
        guard case .legacySymlink(_, false) = pm.claudeDirState() else {
            return XCTFail("expected broken legacy link, got \(pm.claudeDirState())")
        }
        try pm.switchTo(name: "work")
        XCTAssertEqual(pm.activeProfile(), "work")
        XCTAssertTrue(isRealDir(pm.claudeDir))
    }

    func testReservedNamesUntouchable() throws {
        try pm.migrate(name: "main")
        try fm.createDirectory(at: profile("_cli/profiles"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try pm.switchTo(name: "_cli")) {
            XCTAssertEqual($0 as? ProfileError, .profileNotFound("_cli"))
        }
        XCTAssertThrowsError(try pm.deleteProfile(name: "_cli")) {
            XCTAssertEqual($0 as? ProfileError, .profileNotFound("_cli"))
        }
        XCTAssertTrue(isRealDir(profile("_cli/profiles")), "_cli must never be touched")
    }

    // MARK: - Crash recovery

    private func seedForJournal() throws {
        try write("A", to: pm.claudeDir.appendingPathComponent("Cookies"))
        try pm.migrate(name: "a")
        try pm.createProfile(name: "b")
        try write("B", to: profile("b").appendingPathComponent("Cookies"))
    }

    private func plantJournal(_ from: String, _ to: String) throws {
        try write("\(from)\n\(to)\n", to: pm.profilesDir.appendingPathComponent("_switching"))
    }

    private func claudeCookie() -> String? {
        try? String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8)
    }

    func testRepairWhenNothingMoved() throws {
        try seedForJournal()
        try plantJournal("a", "b")
        try pm.repairPendingSwitch()
        XCTAssertEqual(pm.activeProfile(), "a")
        XCTAssertFalse(fm.fileExists(atPath: pm.profilesDir.appendingPathComponent("_switching").path))
    }

    func testRepairRollsForwardAfterFirstRename() throws {
        try seedForJournal()
        try plantJournal("a", "b")
        _ = rename(pm.claudeDir.path, profile("a").path)
        try pm.repairPendingSwitch()
        XCTAssertEqual(pm.activeProfile(), "b")
        XCTAssertEqual(claudeCookie(), "B")
        XCTAssertEqual(try String(contentsOf: profile("a").appendingPathComponent("Cookies"), encoding: .utf8), "A")
    }

    func testRepairFinishesBookkeepingAfterBothRenames() throws {
        try seedForJournal()
        try plantJournal("a", "b")
        _ = rename(pm.claudeDir.path, profile("a").path)
        _ = rename(profile("b").path, pm.claudeDir.path)
        try pm.repairPendingSwitch()
        XCTAssertEqual(pm.activeProfile(), "b")
        XCTAssertEqual(claudeCookie(), "B")
    }

    func testRepairRollsBackWhenTargetVanished() throws {
        try seedForJournal()
        try plantJournal("a", "b")
        _ = rename(pm.claudeDir.path, profile("a").path)
        try fm.removeItem(at: profile("b"))
        try pm.repairPendingSwitch()
        XCTAssertEqual(pm.activeProfile(), "a")
        XCTAssertEqual(claudeCookie(), "A")
    }

    // MARK: - Legacy layout migration

    func testLegacyLayoutMigration() throws {
        let o1 = orgID("1")
        let cp = pm.profilesDir
        for p in ["main", "a", "b"] {
            try fm.createDirectory(at: cp.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        try write("main-data", to: cp.appendingPathComponent("main/Cookies"))
        try writeIDs(account: "acc01111-0000-4000-8000-000000000006", org: o1, into: cp.appendingPathComponent("main"))
        // Claude = absolute symlink (the old app's layout)
        try fm.createSymbolicLink(atPath: pm.claudeDir.path,
                                  withDestinationPath: cp.appendingPathComponent("main").path)
        // _shared-sessions with a master, an absolute org link, and the weird
        // Claude-routed link Claude Desktop itself leaves behind
        let shared = cp.appendingPathComponent("_shared-sessions")
        let master = shared.appendingPathComponent("\(code)/acc01111-0000-4000-8000-000000000006/\(o1)")
        try write("s1", to: master.appendingPathComponent("local_1.json"))
        let orgLink = shared.appendingPathComponent("\(code)/acc02222-0000-4000-8000-000000000007/org02222-0000-4000-8000-000000000009")
        try fm.createDirectory(at: orgLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: orgLink.path, withDestinationPath: master.path)
        let weird = shared.appendingPathComponent("\(code)/acc03333-0000-4000-8000-000000000008/org03333-0000-4000-8000-00000000000a")
        try fm.createDirectory(at: weird.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: weird.path,
                                  withDestinationPath: "../../../../Claude/\(code)/acc01111-0000-4000-8000-000000000006/\(o1)")
        try fm.createDirectory(at: shared.appendingPathComponent(agent), withIntermediateDirectories: true)
        for p in ["main", "a", "b"] {
            for tree in ProfileManager.sessionTrees {
                try fm.createSymbolicLink(atPath: cp.appendingPathComponent("\(p)/\(tree)").path,
                                          withDestinationPath: shared.appendingPathComponent(tree).path)
            }
        }

        try pm.migrateLegacyLayoutIfNeeded()

        XCTAssertEqual(pm.activeProfile(), "main")
        XCTAssertTrue(isRealDir(pm.claudeDir))
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "main-data"
        )
        XCTAssertFalse(fm.fileExists(atPath: shared.path), "_shared-sessions removed")
        XCTAssertTrue(pm.sharedHistoryEnabled)
        let liveMaster = pm.claudeDir.appendingPathComponent("\(code)/acc01111-0000-4000-8000-000000000006/\(o1)")
        XCTAssertTrue(isRealDir(liveMaster), "master moved into the live tree")
        XCTAssertTrue(fm.fileExists(atPath: liveMaster.appendingPathComponent("local_1.json").path))
        XCTAssertEqual(linkTarget(cp.appendingPathComponent("a/\(code)")), "../../Claude/\(code)")
        XCTAssertEqual(linkTarget(pm.claudeDir.appendingPathComponent("\(code)/acc02222-0000-4000-8000-000000000007/org02222-0000-4000-8000-000000000009")),
                       "../acc01111-0000-4000-8000-000000000006/\(o1)")
        XCTAssertEqual(linkTarget(pm.claudeDir.appendingPathComponent("\(code)/acc03333-0000-4000-8000-000000000008/org03333-0000-4000-8000-00000000000a")),
                       "../acc01111-0000-4000-8000-000000000006/\(o1)", "Claude-routed legacy link normalized")
        assertNoSymlinkComponents(liveMaster)

        try pm.migrateLegacyLayoutIfNeeded() // idempotent
        XCTAssertEqual(pm.activeProfile(), "main")
    }

    // MARK: - Shared history (new model)

    /// active "main" (acc0main-0000-4000-8000-000000000001) with one session; "a" (acc0aaaa-0000-4000-8000-000000000002) with one; "b" empty.
    private func seedShared() throws -> (oMain: String, oA: String) {
        let oMain = orgID("a"), oA = orgID("b")
        try makeRealClaudeDir()
        try pm.migrate(name: "main")
        try writeIDs(account: "acc0main-0000-4000-8000-000000000001", org: oMain, into: pm.claudeDir)
        try write("m1", to: pm.claudeDir.appendingPathComponent("\(code)/acc0main-0000-4000-8000-000000000001/\(oMain)/local_1.json"))
        try pm.createProfile(name: "a")
        try pm.createProfile(name: "b")
        try writeIDs(account: "acc0aaaa-0000-4000-8000-000000000002", org: oA, into: profile("a"))
        try write("a1", to: profile("a").appendingPathComponent("\(code)/acc0aaaa-0000-4000-8000-000000000002/\(oA)/local_2.json"))
        return (oMain, oA)
    }

    func testEnableSharedHistoryMergesIntoLiveTree() throws {
        let (oMain, oA) = try seedShared()
        let backup = try XCTUnwrap(try pm.enableSharedHistory())
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("claude-session-backup-"))
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("a/\(code)/acc0aaaa-0000-4000-8000-000000000002/\(oA)/local_2.json"),
                       encoding: .utf8),
            "a1"
        )

        let liveMaster = pm.claudeDir.appendingPathComponent("\(code)/acc0main-0000-4000-8000-000000000001/\(oMain)")
        XCTAssertTrue(isRealDir(liveMaster), "master sits at the ACTIVE account's slot")
        for f in ["local_1.json", "local_2.json"] {
            XCTAssertTrue(fm.fileExists(atPath: liveMaster.appendingPathComponent(f).path), "\(f) merged")
        }
        XCTAssertEqual(linkTarget(profile("a").appendingPathComponent(code)), "../../Claude/\(code)")
        XCTAssertEqual(linkTarget(pm.claudeDir.appendingPathComponent("\(code)/acc0aaaa-0000-4000-8000-000000000002/\(oA)")),
                       "../acc0main-0000-4000-8000-000000000001/\(oMain)")
        assertNoSymlinkComponents(liveMaster)
        // combined list readable through the inactive profile's own path
        XCTAssertTrue(fm.fileExists(
            atPath: profile("a").appendingPathComponent("\(code)/acc0aaaa-0000-4000-8000-000000000002/\(oA)/local_1.json").path
        ))
        XCTAssertNil(try pm.enableSharedHistory(now: Date().addingTimeInterval(60)),
                     "re-run must be a no-op")
    }

    func testSharedSwitchMovesMasterToNewActiveAccount() throws {
        let (oMain, oA) = try seedShared()
        _ = try pm.enableSharedHistory()

        try pm.switchTo(name: "a")
        let aMaster = pm.claudeDir.appendingPathComponent("\(code)/acc0aaaa-0000-4000-8000-000000000002/\(oA)")
        XCTAssertTrue(isRealDir(aMaster), "master follows the active account")
        XCTAssertTrue(fm.fileExists(atPath: aMaster.appendingPathComponent("local_1.json").path))
        XCTAssertEqual(linkTarget(pm.claudeDir.appendingPathComponent("\(code)/acc0main-0000-4000-8000-000000000001/\(oMain)")),
                       "../acc0aaaa-0000-4000-8000-000000000002/\(oA)", "old master slot now a link")
        XCTAssertEqual(linkTarget(profile("main").appendingPathComponent(code)), "../../Claude/\(code)",
                       "previous active got its tree link")
        assertNoSymlinkComponents(aMaster)
    }

    func testCreateProfileAndPrelinkAgainstLiveTree() throws {
        let (_, oA) = try seedShared()
        _ = try pm.enableSharedHistory()
        try pm.switchTo(name: "a")

        try pm.createProfile(name: "fresh")
        XCTAssertEqual(linkTarget(profile("fresh").appendingPathComponent(code)), "../../Claude/\(code)")

        let oFresh = orgID("c")
        try writeIDs(account: "acc0fres-0000-4000-8000-000000000003", org: oFresh, into: profile("fresh"))
        _ = try pm.prelinkKnownAccounts()
        XCTAssertEqual(linkTarget(pm.claudeDir.appendingPathComponent("\(code)/acc0fres-0000-4000-8000-000000000003/\(oFresh)")),
                       "../acc0aaaa-0000-4000-8000-000000000002/\(oA)", "inactive account linked to master")
    }

    func testPrelinkGivesActiveAccountARealDir() throws {
        try pm.migrate(name: "main")
        for tree in ProfileManager.sessionTrees {
            try write("x", to: pm.claudeDir.appendingPathComponent("\(tree)/acc0old0-0000-4000-8000-000000000005/org0old0-0000-4000-8000-00000000000b/s.json"))
        }
        _ = try pm.enableSharedHistory()
        // the active account logs in only after enabling (Claude writes ids live)
        let oLive = orgID("d")
        try writeIDs(account: "acc0live-0000-4000-8000-000000000004", org: oLive, into: pm.claudeDir)
        _ = try pm.prelinkKnownAccounts()
        let live = pm.claudeDir.appendingPathComponent("\(code)/acc0live-0000-4000-8000-000000000004/\(oLive)")
        XCTAssertTrue(isRealDir(live), "the active account's org dir must be real, not a link")
        assertNoSymlinkComponents(live)
    }

    func testDisableSharedHistoryGivesEachProfileACopy() throws {
        let (oMain, oA) = try seedShared()
        _ = try pm.enableSharedHistory()
        try pm.disableSharedHistory()

        XCTAssertFalse(pm.sharedHistoryEnabled)
        // inactive profiles own real trees with the combined copy under their ids
        let aTree = profile("a").appendingPathComponent(code)
        XCTAssertTrue(isRealDir(aTree))
        XCTAssertTrue(fm.fileExists(
            atPath: aTree.appendingPathComponent("acc0aaaa-0000-4000-8000-000000000002/\(oA)/local_1.json").path
        ))
        // the active profile keeps the combined tree it already owns
        XCTAssertTrue(isRealDir(pm.claudeDir.appendingPathComponent("\(code)/acc0main-0000-4000-8000-000000000001/\(oMain)")))
    }

    func testDeleteProfileKeepsSharedHistory() throws {
        let (oMain, _) = try seedShared()
        _ = try pm.enableSharedHistory()
        try pm.deleteProfile(name: "a")
        let master = pm.claudeDir.appendingPathComponent("\(code)/acc0main-0000-4000-8000-000000000001/\(oMain)")
        XCTAssertTrue(fm.fileExists(atPath: master.appendingPathComponent("local_2.json").path),
                      "deleting a profile must not touch the shared sessions")
    }

    // MARK: - Rename / delete

    func testRenameActiveIsBookkeepingOnly() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")
        XCTAssertEqual(try pm.renameProfile("main", to: "primary"), "primary")
        XCTAssertEqual(pm.activeProfile(), "primary")
        XCTAssertEqual(
            try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8),
            "cookie-data"
        )
    }

    func testRenameInactiveMovesDirectory() throws {
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")
        try write("x", to: profile("work").appendingPathComponent("marker.txt"))
        XCTAssertEqual(try pm.renameProfile("work", to: "office"), "office")
        XCTAssertTrue(fm.fileExists(atPath: profile("office").appendingPathComponent("marker.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: profile("work").path))
    }

    func testRenameRejectsCollisionAndUnknown() throws {
        try pm.migrate(name: "active")
        try pm.createProfile(name: "a")
        try pm.createProfile(name: "b")
        XCTAssertThrowsError(try pm.renameProfile("a", to: "b")) {
            XCTAssertEqual($0 as? ProfileError, .profileExists("b"))
        }
        XCTAssertThrowsError(try pm.renameProfile("a", to: "active")) {
            XCTAssertEqual($0 as? ProfileError, .profileExists("active"))
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

    // MARK: - Listing / order

    func testProfilesSkipsUnderscoreAndHiddenDirs() throws {
        try fm.createDirectory(at: profile("alpha"), withIntermediateDirectories: true)
        try fm.createDirectory(at: profile("_cli"), withIntermediateDirectories: true)
        try fm.createDirectory(at: profile(".hidden"), withIntermediateDirectories: true)
        try write("x", to: profile("not-a-dir.txt"))
        XCTAssertEqual(pm.profiles(), ["alpha"])
    }

    func testOrderedRespectsSavedOrderAndPutsUnknownNamesLast() throws {
        try pm.saveOrder(["charlie", "alpha"])
        XCTAssertEqual(pm.savedOrder(), ["charlie", "alpha"])
        XCTAssertEqual(
            pm.ordered(["alpha", "bravo", "charlie", "delta"]),
            ["charlie", "alpha", "bravo", "delta"]
        )
        let fresh = ProfileManager(home: fm.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(fresh.ordered(["b", "a"]), ["a", "b"])
    }

    // MARK: - skills-plugin subtree (non-account data inside the session trees)

    func testSkillsPluginIsNeverConsolidated() throws {
        let o1 = orgID("1")
        let a1 = orgID("7")
        try pm.migrate(name: "main")
        try writeIDs(account: a1, org: o1, into: pm.claudeDir)
        try write("s", to: pm.claudeDir.appendingPathComponent("\(agent)/\(a1)/\(o1)/local_1.json"))
        // healthy skills-plugin: org/account REVERSED order vs sessions, non-uuid root
        let sp = pm.claudeDir.appendingPathComponent("\(agent)/skills-plugin")
        try write("SKILL", to: sp.appendingPathComponent("\(o1)/\(a1)/skills/skill.md"))

        _ = try pm.enableSharedHistory()
        XCTAssertTrue(isRealDir(sp.appendingPathComponent("\(o1)/\(a1)/skills")),
                      "healthy skills subtree must be untouched")
        XCTAssertFalse(isSymlink(sp.appendingPathComponent(o1)))

        try pm.createProfile(name: "other")
        try pm.switchTo(name: "other")
        let after = pm.claudeDir.appendingPathComponent("\(agent)/skills-plugin/\(o1)/\(a1)/skills")
        XCTAssertTrue(isRealDir(after), "skills survive a switch intact")
        assertNoSymlinkComponents(after)
    }

    func testSkillsPluginRepairAfterWrongConsolidation() throws {
        let o1 = orgID("2")
        let a1 = orgID("8")
        try pm.migrate(name: "main")
        try writeIDs(account: a1, org: o1, into: pm.claudeDir)
        let master = pm.claudeDir.appendingPathComponent("\(agent)/\(a1)/\(o1)")
        try write("s", to: master.appendingPathComponent("local_1.json"))
        // the damage an earlier consolidation caused: the skills content got
        // merged INTO the master, and the skills-plugin org dir became a link
        try write("SKILL", to: master.appendingPathComponent("\(a1)/skills/skill.md"))
        let sp = pm.claudeDir.appendingPathComponent("\(agent)/skills-plugin")
        try fm.createDirectory(at: sp, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: sp.appendingPathComponent(o1).path,
                                  withDestinationPath: "../\(a1)/\(o1)")

        _ = try pm.enableSharedHistory() // normalize runs → repair runs

        let restored = sp.appendingPathComponent("\(o1)/\(a1)/skills")
        XCTAssertFalse(isSymlink(sp.appendingPathComponent(o1)), "wrong link removed")
        XCTAssertTrue(isRealDir(restored), "captured skills moved back out of the master")
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("skill.md"), encoding: .utf8),
                       "SKILL")
        XCTAssertFalse(fm.fileExists(atPath: master.appendingPathComponent("\(a1)/skills").path),
                       "master no longer holds the captured copy")
        assertNoSymlinkComponents(restored)

        _ = try pm.enableSharedHistory() // idempotent
        XCTAssertTrue(isRealDir(restored))
    }

    // MARK: - The Cowork guarantee, end to end

    /// Mirror the whole home under a different root — exactly what Cowork's VM
    /// sees through virtiofs — and verify the active session path resolves with
    /// zero symlink components while inactive profiles still resolve via links.
    func testVMShiftSimulation() throws {
        let o1 = orgID("e")
        try makeRealClaudeDir()
        try pm.migrate(name: "main")
        try writeIDs(account: "acc01111-0000-4000-8000-000000000006", org: o1, into: pm.claudeDir)
        try write("s", to: pm.claudeDir.appendingPathComponent("\(code)/acc01111-0000-4000-8000-000000000006/\(o1)/local_1.json"))
        try pm.createProfile(name: "other")
        _ = try pm.enableSharedHistory()

        let guest = home.appendingPathComponent("guestmount/shared")
        try fm.createDirectory(at: guest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: home.appendingPathComponent("Library"), to: guest)

        let guestSession = guest.appendingPathComponent("Application Support/Claude/\(code)/acc01111-0000-4000-8000-000000000006/\(o1)")
        var cur = guest
        for c in guestSession.pathComponents[guest.pathComponents.count...] {
            cur = cur.appendingPathComponent(c)
            XCTAssertFalse(isSymlink(cur), "\(cur.path) is a symlink — Cowork would refuse")
        }
        XCTAssertTrue(fm.fileExists(atPath: guestSession.appendingPathComponent("local_1.json").path))
        XCTAssertTrue(fm.fileExists(atPath: guest
            .appendingPathComponent("Application Support/Claude-Profiles/other/\(code)/acc01111-0000-4000-8000-000000000006/\(o1)/local_1.json").path),
            "inactive profile's relative chain resolves under the shifted root")
    }
}
