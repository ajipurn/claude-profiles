import Foundation

public enum ProfileError: LocalizedError, Equatable {
    case invalidName
    case profileExists(String)
    case profileNotFound(String)
    case refusedToClobber(String)
    case nothingToMigrate
    case profileIsActive(String)
    case inconsistentState(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Profile name must contain at least one of A–Z, 0–9, _ or -."
        case .profileExists(let name):
            return "Profile “\(name)” already exists."
        case .profileNotFound(let name):
            return "Profile “\(name)” does not exist."
        case .refusedToClobber(let path):
            return "\(path) already exists; refusing to touch it."
        case .nothingToMigrate:
            return "The Claude directory is already managed; migration is not needed."
        case .profileIsActive(let name):
            return "Profile “\(name)” is active; switch away before deleting it."
        case .inconsistentState(let detail):
            return "Profile layout needs attention: \(detail)"
        }
    }
}

public enum ClaudeDirState: Equatable {
    case missing
    /// A real, unmanaged Claude directory — the pre-setup state.
    case realDirectory
    /// A real Claude directory owned by the app; it *is* the active profile.
    case managed(active: String)
    /// The pre-1.5 layout (Claude was a symlink into Claude-Profiles).
    /// Migrated automatically at launch; sticks around only when broken.
    case legacySymlink(target: URL?, valid: Bool)
    case otherFile
}

/// All filesystem logic. No UI, no AppKit — fully testable against a fake home directory.
///
/// Layout: `Application Support/Claude` is a *real directory* holding the active
/// profile's data; inactive profiles are real directories in `Claude-Profiles/`.
/// Switching renames the two (same volume — instant). No symlink is ever part of
/// the active profile's path: Claude's Cowork feature mounts session directories
/// into a VM with openat2(RESOLVE_NO_SYMLINKS), which refuses to traverse *any*
/// symlink — the earlier symlink-based layout broke every Cowork session.
public final class ProfileManager {
    public static let sessionTrees = ["claude-code-sessions", "local-agent-mode-sessions"]

    public let home: URL
    private let fm = FileManager.default

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    public var claudeDir: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    public var profilesDir: URL { home.appendingPathComponent("Library/Application Support/Claude-Profiles") }
    /// The pre-1.5 shared-history store; only read by the migration.
    public var legacySharedDir: URL { profilesDir.appendingPathComponent("_shared-sessions") }

    // App-owned state, all `_`-prefixed so profiles() never lists it.
    private var activeFile: URL { profilesDir.appendingPathComponent("_active") }
    private var switchJournal: URL { profilesDir.appendingPathComponent("_switching") }
    private var sharedMarker: URL { profilesDir.appendingPathComponent("_shared-history") }
    // Display order for the unified list, one name per line. Order is a plain
    // list, never dir renames — renaming a profile would log its CLI side out
    // (path = Keychain identity).
    private var orderFile: URL { profilesDir.appendingPathComponent("_order") }

    // MARK: - Inspection

    public func claudeDirState() -> ClaudeDirState {
        guard let type = itemType(claudeDir) else { return .missing }
        switch type {
        case .typeSymbolicLink:
            let target = (try? fm.destinationOfSymbolicLink(atPath: claudeDir.path))
                .map { URL(fileURLWithPath: $0, relativeTo: claudeDir.deletingLastPathComponent()).standardizedFileURL }
            let valid = target.map { isRealDirectory($0) } ?? false
            return .legacySymlink(target: target, valid: valid)
        case .typeDirectory:
            if let name = readActive() { return .managed(active: name) }
            return .realDirectory
        default:
            return .otherFile
        }
    }

    public func activeProfile() -> String? {
        guard case .managed(let name) = claudeDirState() else { return nil }
        return name
    }

    /// Every profile, the active one included (it has no directory under
    /// Claude-Profiles — its data *is* the Claude directory).
    public func profiles() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: profilesDir.path)) ?? []
        var out = names.filter {
            !$0.hasPrefix("_") && !$0.hasPrefix(".") && isRealDirectory(profilesDir.appendingPathComponent($0))
        }
        if let active = activeProfile(), !out.contains(active) { out.append(active) }
        return out.sorted()
    }

    /// Where a profile's data lives right now.
    public func profileDir(_ name: String) -> URL {
        activeProfile() == name ? claudeDir : profilesDir.appendingPathComponent(name)
    }

    public var sharedHistoryEnabled: Bool {
        itemExists(sharedMarker) || isRealDirectory(legacySharedDir)
    }

    public func savedOrder() -> [String] {
        guard let raw = try? String(contentsOf: orderFile, encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline).map(String.init)
    }

    public func saveOrder(_ names: [String]) throws {
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try (names.joined(separator: "\n") + "\n").write(to: orderFile, atomically: true, encoding: .utf8)
    }

    /// Sort `names` by the saved order; names not in the file (created outside
    /// the app, or before ordering existed) fall to the end alphabetically — so
    /// a freshly created profile shows up last until the user drags it.
    public func ordered(_ names: [String]) -> [String] {
        let rank = Dictionary(savedOrder().enumerated().map { ($1, $0) },
                              uniquingKeysWith: { first, _ in first })
        return names.sorted {
            switch (rank[$0], rank[$1]) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return $0 < $1
            }
        }
    }

    public static func sanitize(_ raw: String) -> String? {
        // @ and . allowed so email addresses work as profile names.
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-@."
        var name = String(raw.filter { allowed.contains($0) })
        // Leading `_`/`.` collide with app-internal names (_cli, _active, …)
        // and hidden files; profiles() would never even list them.
        while let first = name.first, first == "_" || first == "." { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    private func isReservedName(_ name: String) -> Bool {
        name.hasPrefix("_") || name.hasPrefix(".")
    }

    // MARK: - Operations

    /// First-run setup: adopt the Claude directory, in place, as profile `name`.
    /// Nothing moves — the directory just gains an owner — so this step can
    /// never lose data.
    public func migrate(name rawName: String) throws {
        guard let name = Self.sanitize(rawName) else { throw ProfileError.invalidName }
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        guard !itemExists(profilesDir.appendingPathComponent(name)) else {
            throw ProfileError.profileExists(name)
        }
        switch claudeDirState() {
        case .realDirectory:
            try writeActive(name)
        case .missing:
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try writeActive(name)
        case .managed, .legacySymlink, .otherFile:
            throw ProfileError.nothingToMigrate
        }
    }

    /// Swap the active profile: journal the intent, rename the Claude directory
    /// out to the old profile's slot, rename the new profile's directory in,
    /// then fix up shared-history links. Each rename is a single atomic
    /// same-volume syscall; a crash at any point leaves a state
    /// repairPendingSwitch() can finish or roll back deterministically.
    public func switchTo(name: String) throws {
        try migrateLegacyLayoutIfNeeded()
        // `_`/`.` names are app-internal (_cli, _shared state files) — never
        // profiles, even when a directory of that name exists.
        guard !isReservedName(name) else { throw ProfileError.profileNotFound(name) }
        let dest = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(dest) else { throw ProfileError.profileNotFound(name) }
        switch claudeDirState() {
        case .managed(let from):
            guard name != from else { return }
            let fromSlot = profilesDir.appendingPathComponent(from)
            guard !itemExists(fromSlot) else { throw ProfileError.refusedToClobber(fromSlot.path) }
            try writeJournal(from: from, to: name)
            try renameOrThrow(claudeDir, to: fromSlot)
            try renameOrThrow(dest, to: claudeDir)
            try sharedFixups(oldActive: from)
            try writeActive(name)
            try? fm.removeItem(at: switchJournal)
        case .missing:
            // Nothing to preserve — install the profile directly.
            try renameOrThrow(dest, to: claudeDir)
            try sharedFixups(oldActive: nil)
            try writeActive(name)
        case .legacySymlink(_, false):
            // Dangling link from the old layout; replacing it loses nothing.
            try fm.removeItem(at: claudeDir)
            try renameOrThrow(dest, to: claudeDir)
            try sharedFixups(oldActive: nil)
            try writeActive(name)
        case .realDirectory, .legacySymlink, .otherFile:
            throw ProfileError.refusedToClobber(claudeDir.path)
        }
    }

    /// Finish or roll back a switch that was interrupted by a crash. Safe to
    /// call any time; a no-op when no switch is pending.
    public func repairPendingSwitch() throws {
        guard let (from, to) = readJournal() else { return }
        let claudeExists = itemExists(claudeDir)
        let toSlot = profilesDir.appendingPathComponent(to)
        let fromSlot = profilesDir.appendingPathComponent(from)
        switch (claudeExists, itemExists(toSlot)) {
        case (true, true):
            // Neither rename happened — the old profile is still in place.
            try? fm.removeItem(at: switchJournal)
        case (false, true):
            // Claude was renamed out but the new profile never moved in.
            try renameOrThrow(toSlot, to: claudeDir)
            try sharedFixups(oldActive: from)
            try writeActive(to)
            try? fm.removeItem(at: switchJournal)
        case (true, false):
            // Both renames happened; only the fixups/bookkeeping remained.
            try sharedFixups(oldActive: from)
            try writeActive(to)
            try? fm.removeItem(at: switchJournal)
        case (false, false):
            // No Claude dir and no new profile — roll back to the old one.
            guard itemExists(fromSlot) else {
                throw ProfileError.inconsistentState(
                    "interrupted switch \(from) → \(to): neither profile found")
            }
            try renameOrThrow(fromSlot, to: claudeDir)
            try writeActive(from)
            try? fm.removeItem(at: switchJournal)
        }
    }

    /// One-time, launch-time upgrade from the pre-1.5 symlink layout:
    /// the Claude symlink becomes the real directory, `_shared-sessions` moves
    /// into the active profile, and every remaining app-made symlink is
    /// rewritten against the new layout.
    public func migrateLegacyLayoutIfNeeded() throws {
        try repairPendingSwitch()

        // Finish an interrupted migration (crash between unlink and rename below):
        // the recorded active profile exists but nothing sits at the Claude path.
        if claudeDirState() == .missing, let name = readActive() {
            let slot = profilesDir.appendingPathComponent(name)
            if isRealDirectory(slot) { try renameOrThrow(slot, to: claudeDir) }
        }

        if case .legacySymlink(let target?, true) = claudeDirState(),
           target.deletingLastPathComponent().path == profilesDir.path {
            // rename(2) cannot move a directory over a symlink (ENOTDIR), so
            // this is unlink + rename; the _active record written first makes
            // the two-syscall window recoverable (see above).
            try writeActive(target.lastPathComponent)
            try fm.removeItem(at: claudeDir)
            try renameOrThrow(target, to: claudeDir)
        }

        guard case .managed(let active) = claudeDirState() else { return }

        if isRealDirectory(legacySharedDir) {
            try touch(sharedMarker)
            for tree in Self.sessionTrees {
                let live = claudeDir.appendingPathComponent(tree)
                if isSymlink(live) { try fm.removeItem(at: live) }
                let legacy = legacySharedDir.appendingPathComponent(tree)
                if isRealDirectory(legacy) {
                    if !itemExists(live) {
                        try renameOrThrow(legacy, to: live)
                    } else {
                        try merge(contentsOf: legacy, into: live)
                        try fm.removeItem(at: legacy)
                    }
                } else if !itemExists(live) {
                    try fm.createDirectory(at: live, withIntermediateDirectories: true)
                }
            }
            // Only the session trees ever lived there; leave anything unexpected.
            if let rest = try? fm.contentsOfDirectory(atPath: legacySharedDir.path),
               rest.filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.removeItem(at: legacySharedDir)
            }
        }

        if sharedHistoryEnabled {
            for profile in profiles() where profile != active {
                for tree in Self.sessionTrees {
                    let link = profilesDir.appendingPathComponent(profile).appendingPathComponent(tree)
                    guard isSymlink(link) else { continue }
                    try fm.removeItem(at: link)
                    try createRelativeSymlink(at: link, to: claudeDir.appendingPathComponent(tree))
                }
            }
            for tree in Self.sessionTrees {
                try normalizeSessionTree(claudeDir.appendingPathComponent(tree))
            }
        }
    }

    @discardableResult
    public func createProfile(name rawName: String) throws -> String {
        guard let name = Self.sanitize(rawName) else { throw ProfileError.invalidName }
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        guard name != activeProfile() else { throw ProfileError.profileExists(name) }
        let dir = profilesDir.appendingPathComponent(name)
        guard !itemExists(dir) else { throw ProfileError.profileExists(name) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if sharedHistoryEnabled {
            for tree in Self.sessionTrees {
                let live = claudeDir.appendingPathComponent(tree)
                guard isRealDirectory(live) else { continue }
                try createRelativeSymlink(at: dir.appendingPathComponent(tree), to: live)
            }
        }
        return name
    }

    // MARK: - Rename / delete

    /// Rename a profile. The active one has no directory of its own, so its
    /// rename is pure bookkeeping; an inactive one is a directory move.
    @discardableResult
    public func renameProfile(_ name: String, to rawNewName: String) throws -> String {
        guard let newName = Self.sanitize(rawNewName) else { throw ProfileError.invalidName }
        guard newName != name else { return name }
        guard !itemExists(profilesDir.appendingPathComponent(newName)), newName != activeProfile() else {
            throw ProfileError.profileExists(newName)
        }
        if activeProfile() == name {
            try writeActive(newName)
            return newName
        }
        let src = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(src) else { throw ProfileError.profileNotFound(name) }
        try fm.moveItem(at: src, to: profilesDir.appendingPathComponent(newName))
        return newName
    }

    /// Delete a profile — this is "logout": the account's login state is removed.
    /// The active profile can never be deleted (it is the live Claude directory).
    public func deleteProfile(name: String) throws {
        guard activeProfile() != name else { throw ProfileError.profileIsActive(name) }
        guard !isReservedName(name) else { throw ProfileError.profileNotFound(name) }
        let dir = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(dir) else { throw ProfileError.profileNotFound(name) }
        try fm.removeItem(at: dir) // shared trees are symlinks inside it — shared history survives
    }

    // MARK: - Shared history

    /// Merge every profile's session trees into the active profile's (the live
    /// Claude directory) and link the others back to it. The live tree is the
    /// master copy on purpose: the active profile's session paths must contain
    /// no symlink at all, or Cowork's VM refuses to mount them.
    /// Returns the backup directory, or nil when there was nothing to move
    /// (idempotent re-run).
    @discardableResult
    public func enableSharedHistory(now: Date = Date()) throws -> URL? {
        try migrateLegacyLayoutIfNeeded()
        guard case .managed(let active) = claudeDirState() else {
            throw ProfileError.inconsistentState("set up profiles before sharing history")
        }
        let names = profiles()

        // Backup first: copy every inactive real (not yet linked) session tree.
        // The live tree never moves — merges only ever add files to it.
        var realTrees: [(profile: String, tree: String)] = []
        for profile in names where profile != active {
            for tree in Self.sessionTrees
            where isRealDirectory(profilesDir.appendingPathComponent(profile).appendingPathComponent(tree)) {
                realTrees.append((profile, tree))
            }
        }
        var backup: URL?
        if !realTrees.isEmpty {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupDir = home.appendingPathComponent("claude-session-backup-\(fmt.string(from: now))")
            for (profile, tree) in realTrees {
                let src = profilesDir.appendingPathComponent(profile).appendingPathComponent(tree)
                let dst = backupDir.appendingPathComponent(profile).appendingPathComponent(tree)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dst)
            }
            backup = backupDir
        }

        try touch(sharedMarker)
        for tree in Self.sessionTrees {
            let live = claudeDir.appendingPathComponent(tree)
            if isSymlink(live) { try fm.removeItem(at: live) }
            if !itemExists(live) {
                try fm.createDirectory(at: live, withIntermediateDirectories: true)
            }
            for profile in names where profile != active {
                let link = profilesDir.appendingPathComponent(profile).appendingPathComponent(tree)
                if isSymlink(link) {
                    try fm.removeItem(at: link) // re-created below with the current target
                } else if isRealDirectory(link) {
                    try merge(contentsOf: link, into: live)
                    try fm.removeItem(at: link)
                }
                try createRelativeSymlink(at: link, to: live)
            }
            let master = try normalizeSessionTree(live)
            try prelinkAccounts(in: live, master: master, profiles: names, active: active)
        }
        return backup
    }

    /// Undo sharing. Merged sessions cannot be split back per account, so the
    /// honest semantics are: every profile keeps its own real copy of the
    /// combined history (for the account/org ids Claude recorded at login),
    /// and sessions created afterwards stay per-profile. The active profile
    /// already owns the combined tree; inactive ones get their copy.
    public func disableSharedHistory() throws {
        guard sharedHistoryEnabled else { return }
        try migrateLegacyLayoutIfNeeded()
        guard case .managed(let active) = claudeDirState() else { return }
        for tree in Self.sessionTrees {
            let live = claudeDir.appendingPathComponent(tree)
            for profile in profiles() where profile != active {
                let profileDir = profilesDir.appendingPathComponent(profile)
                let link = profileDir.appendingPathComponent(tree)
                guard isSymlink(link) else { continue }
                try fm.removeItem(at: link)
                try fm.createDirectory(at: link, withIntermediateDirectories: true)
                guard isRealDirectory(live), let account = accountID(of: profileDir) else { continue }
                for org in orgIDs(of: profileDir) {
                    let src = live.appendingPathComponent(account).appendingPathComponent(org)
                        .resolvingSymlinksInPath()
                    let dst = link.appendingPathComponent(account).appendingPathComponent(org)
                    guard isRealDirectory(src), !itemExists(dst) else { continue }
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: src, to: dst)
                }
            }
        }
        try? fm.removeItem(at: sharedMarker)
    }

    /// Safe while Claude is running: only creates missing directories/symlinks —
    /// never merges, moves, or deletes. Lets an account that just logged in join
    /// the combined list without waiting for a full quit-time merge.
    /// Returns how many were created — nonzero means Claude needs a restart
    /// to pick them up (its sidebar is already loaded in memory).
    @discardableResult
    public func prelinkKnownAccounts() throws -> Int {
        guard sharedHistoryEnabled, case .managed(let active) = claudeDirState() else { return 0 }
        let names = profiles()
        var created = 0
        for tree in Self.sessionTrees {
            let live = claudeDir.appendingPathComponent(tree)
            guard isRealDirectory(live) else { continue }
            var orgDirs: [URL] = []
            for account in try realSubdirectories(of: live) where isUUIDLike(account.lastPathComponent) {
                orgDirs.append(contentsOf: try realSubdirectories(of: account)
                    .filter { isUUIDLike($0.lastPathComponent) })
            }
            // Steady state has exactly one real org dir (the master). More than one
            // means a merge is pending — leave that to the next quit-time relink.
            guard orgDirs.count == 1 else { continue }
            created += try prelinkAccounts(in: live, master: orgDirs[0], profiles: names, active: active)
        }
        return created
    }

    /// Accounts that logged in but never opened a Code/agent session have no
    /// <account>/<org> dir at all, so their sidebar stays empty even after a merge.
    /// Claude records both uuids in the profile right after login — use them to
    /// wire the account's org dir to the master ahead of time. The *active*
    /// account gets a real directory (Cowork must be able to mount through it);
    /// everyone else gets a symlink.
    @discardableResult
    private func prelinkAccounts(in tree: URL, master: URL?, profiles names: [String], active: String) throws -> Int {
        guard let master else { return 0 }
        var created = 0
        for profile in names {
            let dir = profileDir(profile)
            guard let account = accountID(of: dir) else { continue }
            for org in orgIDs(of: dir) {
                let orgDir = tree.appendingPathComponent(account).appendingPathComponent(org)
                guard !itemExists(orgDir) else { continue } // real or already linked
                try fm.createDirectory(at: orgDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                if profile == active {
                    try fm.createDirectory(at: orgDir, withIntermediateDirectories: true)
                } else {
                    try createRelativeSymlink(at: orgDir, to: master)
                }
                created += 1
            }
        }
        return created
    }

    /// True once Claude has written the profile's account/org ids — i.e. the
    /// account has completed its first login. Before that, prelinking is
    /// impossible (the ids are unknowable), which is why a brand-new profile's
    /// sidebar starts empty even with shared history on.
    public func hasAccountIDs(profile name: String) -> Bool {
        let dir = profileDir(name)
        return accountID(of: dir) != nil && !orgIDs(of: dir).isEmpty
    }

    /// Last usage-limit numbers Claude Desktop saw for this profile's account,
    /// read from the profile's own HTTP cache. Nil when nothing is cached.
    public func usage(profile name: String) -> ProfileUsage? {
        let dir = profileDir(name)
        return UsageReader.usage(inProfileDir: dir, orgIDs: orgIDs(of: dir))
    }

    /// ownerAccountId from cowork-enabled-cli-ops.json — written on login.
    private func accountID(of profileDir: URL) -> String? {
        guard let data = try? Data(contentsOf: profileDir.appendingPathComponent("cowork-enabled-cli-ops.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["ownerAccountId"] as? String
    }

    /// Org uuids from config.json `dxt:<name>:<org-uuid>` keys — written on login.
    private func orgIDs(of profileDir: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: profileDir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var ids: Set<String> = []
        for key in json.keys where key.hasPrefix("dxt:") {
            let parts = key.split(separator: ":")
            if parts.count == 3, parts[2].count == 36 { ids.insert(String(parts[2])) }
        }
        return ids
    }

    // MARK: - Internals

    /// After the active profile changed hands: pull the shared trees into the
    /// live Claude directory, leave a link behind in the old profile, and put
    /// the master org dir where the now-active account needs it. Idempotent —
    /// crash recovery re-runs it wholesale.
    private func sharedFixups(oldActive: String?) throws {
        guard sharedHistoryEnabled else { return }
        for tree in Self.sessionTrees {
            let live = claudeDir.appendingPathComponent(tree)
            if isSymlink(live) { try fm.removeItem(at: live) }
            let oldTree = oldActive.map {
                profilesDir.appendingPathComponent($0).appendingPathComponent(tree)
            }
            if !itemExists(live) {
                if let oldTree, isRealDirectory(oldTree) {
                    try renameOrThrow(oldTree, to: live)
                } else {
                    try fm.createDirectory(at: live, withIntermediateDirectories: true)
                }
            }
            if let oldTree, let old = oldActive,
               isRealDirectory(profilesDir.appendingPathComponent(old)), !itemExists(oldTree) {
                try createRelativeSymlink(at: oldTree, to: live)
            }
            try normalizeSessionTree(live)
        }
    }

    /// Inside a live session tree: merge stray real org dirs into one master,
    /// move the master to the active account's own <account>/<org> slot (its
    /// paths must be symlink-free for Cowork), and point every other org dir
    /// at it with a relative link. Returns the master, if the tree has one.
    /// Accounts with several orgs keep the master under their first org;
    /// secondary orgs stay links — combined history over Cowork there.
    ///
    /// Only uuid-named <account>/<org> pairs take part: the trees also hold
    /// non-account subtrees (`skills-plugin/<org>/<account>/skills`) that must
    /// never be consolidated — Cowork mounts them read-only by their own path.
    @discardableResult
    private func normalizeSessionTree(_ tree: URL) throws -> URL? {
        guard isRealDirectory(tree) else { return nil }

        var realOrgs: [URL] = []
        var linkSites: [URL] = []
        for account in try realSubdirectories(of: tree) where isUUIDLike(account.lastPathComponent) {
            for entry in (try? fm.contentsOfDirectory(atPath: account.path)) ?? []
            where isUUIDLike(entry) {
                let url = account.appendingPathComponent(entry)
                if isRealDirectory(url) { realOrgs.append(url) }
                else if isSymlink(url) { linkSites.append(url) }
            }
        }

        // One real org dir survives: the one with the most files (fewest moves).
        realOrgs.sort { $0.path < $1.path } // deterministic tie-break
        var master = realOrgs.first
        var bestCount = master.map(fileCount(in:)) ?? 0
        for dir in realOrgs.dropFirst() {
            let count = fileCount(in: dir)
            if count > bestCount { master = dir; bestCount = count }
        }
        for dir in realOrgs where dir.path != master?.path {
            try merge(contentsOf: dir, into: master!)
            try fm.removeItem(at: dir)
            linkSites.append(dir)
        }

        // The active account's org slot must be the real one.
        if let account = accountID(of: claudeDir),
           let org = orgIDs(of: claudeDir).sorted().first {
            let want = tree.appendingPathComponent(account).appendingPathComponent(org)
            if isSymlink(want) {
                try fm.removeItem(at: want)
                linkSites.removeAll { $0.path == want.path }
            }
            if let m = master {
                if m.path != want.path, !itemExists(want) {
                    try fm.createDirectory(at: want.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try renameOrThrow(m, to: want)
                    linkSites.append(m) // anything resolving the old path keeps working
                    master = want
                }
            } else {
                try fm.createDirectory(at: want, withIntermediateDirectories: true)
                master = want
            }
        }

        try repairNonAccountSubtrees(in: tree, master: master)
        guard let master else { return nil }
        for site in linkSites where site.path != master.path {
            if isSymlink(site) { try fm.removeItem(at: site) }
            guard !itemExists(site) else { continue }
            try fm.createDirectory(at: site.deletingLastPathComponent(), withIntermediateDirectories: true)
            try createRelativeSymlink(at: site, to: master)
        }
        return master
    }

    /// The session trees hold non-account subtrees too (`skills-plugin/<org>/
    /// <account>/skills`, mounted read-only by Cowork). Earlier consolidation
    /// passes mistook them for accounts: their org dirs became links into the
    /// session master and their content was merged into it — after which
    /// Cowork refused to mount skills through the link. Undo both: drop the
    /// links (Claude re-syncs skills on its own) and move the active pair's
    /// captured content back out of the master.
    private func repairNonAccountSubtrees(in tree: URL, master: URL?) throws {
        for name in (try? fm.contentsOfDirectory(atPath: tree.path)) ?? []
        where !isUUIDLike(name) && !name.hasPrefix(".") {
            let sub = tree.appendingPathComponent(name)
            if isSymlink(sub) {
                try fm.removeItem(at: sub)
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            }
            guard isRealDirectory(sub) else { continue }
            for org in (try? fm.contentsOfDirectory(atPath: sub.path)) ?? []
            where isSymlink(sub.appendingPathComponent(org)) {
                try fm.removeItem(at: sub.appendingPathComponent(org))
            }
        }
        guard let master,
              let account = accountID(of: claudeDir),
              let org = orgIDs(of: claudeDir).sorted().first else { return }
        let skillsPlugin = tree.appendingPathComponent("skills-plugin")
        guard isRealDirectory(skillsPlugin) else { return }
        let dst = skillsPlugin.appendingPathComponent(org).appendingPathComponent(account)
        let captured = master.appendingPathComponent(account)
        if !itemExists(dst), isRealDirectory(captured.appendingPathComponent("skills")) {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try renameOrThrow(captured, to: dst)
        }
    }

    /// Account and org directory names are uuids; anything else in a session
    /// tree is app data that consolidation must leave alone.
    private func isUUIDLike(_ name: String) -> Bool { name.count == 36 }

    /// Recursive copy that never overwrites an existing file.
    private func merge(contentsOf src: URL, into dst: URL) throws {
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appendingPathComponent(name)
            let d = dst.appendingPathComponent(name)
            if !itemExists(d) {
                try fm.copyItem(at: s, to: d)
            } else if isRealDirectory(s), isRealDirectory(d) {
                try merge(contentsOf: s, into: d)
            }
            // else: destination exists — never overwrite.
        }
    }

    // MARK: - State files

    private func readActive() -> String? {
        guard let raw = try? String(contentsOf: activeFile, encoding: .utf8) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func writeActive(_ name: String) throws {
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try (name + "\n").write(to: activeFile, atomically: true, encoding: .utf8)
    }

    private func readJournal() -> (from: String, to: String)? {
        guard let raw = try? String(contentsOf: switchJournal, encoding: .utf8) else { return nil }
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 2 else { return nil }
        return (lines[0], lines[1])
    }

    private func writeJournal(from: String, to: String) throws {
        try (from + "\n" + to + "\n").write(to: switchJournal, atomically: true, encoding: .utf8)
    }

    private func touch(_ url: URL) throws {
        guard !itemExists(url) else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func renameOrThrow(_ src: URL, to dst: URL) throws {
        guard rename(src.path, dst.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // Every symlink the app creates uses a *relative* target: absolute /Users/…
    // targets dangle inside Cowork's VM, which mounts the host disk under its
    // own root. (Inactive profiles' paths may contain links; the active one never.)
    private func createRelativeSymlink(at link: URL, to dest: URL) throws {
        try fm.createSymbolicLink(atPath: link.path,
                                  withDestinationPath: relativePath(from: link.deletingLastPathComponent(), to: dest))
    }

    private func relativePath(from base: URL, to dest: URL) -> String {
        let b = base.standardizedFileURL.pathComponents
        let d = dest.standardizedFileURL.pathComponents
        var common = 0
        while common < min(b.count, d.count), b[common] == d[common] { common += 1 }
        let path = (Array(repeating: "..", count: b.count - common) + d[common...]).joined(separator: "/")
        return path.isEmpty ? "." : path
    }

    private func realSubdirectories(of url: URL) throws -> [URL] {
        guard isRealDirectory(url) else { return [] }
        return try fm.contentsOfDirectory(atPath: url.path)
            .map { url.appendingPathComponent($0) }
            .filter { isRealDirectory($0) }
    }

    private func fileCount(in dir: URL) -> Int {
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let file as URL in enumerator
        where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            count += 1
        }
        return count
    }

    // lstat semantics: attributesOfItem does not traverse the final symlink,
    // so these are safe on broken symlinks and never confuse a link with a dir.
    private func itemType(_ url: URL) -> FileAttributeType? {
        (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private func itemExists(_ url: URL) -> Bool { itemType(url) != nil }
    private func isSymlink(_ url: URL) -> Bool { itemType(url) == .typeSymbolicLink }
    private func isRealDirectory(_ url: URL) -> Bool { itemType(url) == .typeDirectory }
}
