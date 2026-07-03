import Foundation

public enum ProfileError: LocalizedError, Equatable {
    case invalidName
    case profileExists(String)
    case profileNotFound(String)
    case refusedToClobber(String)
    case nothingToMigrate
    case profileIsActive(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Profile name must contain at least one of A–Z, 0–9, _ or -."
        case .profileExists(let name):
            return "Profile “\(name)” already exists."
        case .profileNotFound(let name):
            return "Profile “\(name)” does not exist."
        case .refusedToClobber(let path):
            return "\(path) exists and is not a symlink; refusing to touch it."
        case .nothingToMigrate:
            return "The Claude directory is already managed; migration is not needed."
        case .profileIsActive(let name):
            return "Profile “\(name)” is active; switch away before deleting it."
        }
    }
}

public enum ClaudeDirState: Equatable {
    case missing
    case realDirectory
    case symlink(target: URL?, valid: Bool)
    case otherFile
}

/// All filesystem logic. No UI, no AppKit — fully testable against a fake home directory.
public final class ProfileManager {
    public static let sessionTrees = ["claude-code-sessions", "local-agent-mode-sessions"]

    public let home: URL
    private let fm = FileManager.default

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    public var claudeDir: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    public var profilesDir: URL { home.appendingPathComponent("Library/Application Support/Claude-Profiles") }
    public var sharedDir: URL { profilesDir.appendingPathComponent("_shared-sessions") }

    // MARK: - Inspection

    public func claudeDirState() -> ClaudeDirState {
        guard let type = itemType(claudeDir) else { return .missing }
        switch type {
        case .typeSymbolicLink:
            let target = (try? fm.destinationOfSymbolicLink(atPath: claudeDir.path))
                .map { URL(fileURLWithPath: $0, relativeTo: claudeDir.deletingLastPathComponent()).standardizedFileURL }
            let valid = target.map { isRealDirectory($0) } ?? false
            return .symlink(target: target, valid: valid)
        case .typeDirectory:
            return .realDirectory
        default:
            return .otherFile
        }
    }

    public func profiles() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: profilesDir.path)) ?? []
        return names
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && isRealDirectory(profilesDir.appendingPathComponent($0)) }
            .sorted()
    }

    public func activeProfile() -> String? {
        guard case .symlink(let target?, true) = claudeDirState(),
              target.deletingLastPathComponent().path == profilesDir.path
        else { return nil }
        return target.lastPathComponent
    }

    public var sharedHistoryEnabled: Bool { isRealDirectory(sharedDir) }

    public static func sanitize(_ raw: String) -> String? {
        // @ and . allowed so email addresses work as profile names.
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-@."
        let name = String(raw.filter { allowed.contains($0) })
        return name.isEmpty || name.allSatisfy({ $0 == "." }) ? nil : name
    }

    // MARK: - Operations

    /// First-run migration: move the real Claude dir into a profile (or create an
    /// empty profile if the dir is missing) and replace it with a symlink.
    public func migrate(name rawName: String) throws {
        guard let name = Self.sanitize(rawName) else { throw ProfileError.invalidName }
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let dest = profilesDir.appendingPathComponent(name)
        guard !itemExists(dest) else { throw ProfileError.profileExists(name) }

        switch claudeDirState() {
        case .realDirectory:
            try fm.moveItem(at: claudeDir, to: dest)
        case .missing:
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        case .symlink, .otherFile:
            throw ProfileError.nothingToMigrate
        }
        try pointClaudeDir(at: dest)
    }

    public func switchTo(name: String) throws {
        let dest = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(dest) else { throw ProfileError.profileNotFound(name) }
        try pointClaudeDir(at: dest)
    }

    @discardableResult
    public func createProfile(name rawName: String) throws -> String {
        guard let name = Self.sanitize(rawName) else { throw ProfileError.invalidName }
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let dir = profilesDir.appendingPathComponent(name)
        guard !itemExists(dir) else { throw ProfileError.profileExists(name) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if sharedHistoryEnabled {
            for tree in Self.sessionTrees {
                let sharedTree = sharedDir.appendingPathComponent(tree)
                guard isRealDirectory(sharedTree) else { continue }
                try fm.createSymbolicLink(at: dir.appendingPathComponent(tree), withDestinationURL: sharedTree)
            }
        }
        return name
    }

    // MARK: - Rename / delete

    /// Rename a profile. If it is the active one, the symlink is repointed —
    /// callers must have Claude quit in that case.
    @discardableResult
    public func renameProfile(_ name: String, to rawNewName: String) throws -> String {
        guard let newName = Self.sanitize(rawNewName) else { throw ProfileError.invalidName }
        guard newName != name else { return name }
        let src = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(src) else { throw ProfileError.profileNotFound(name) }
        let dst = profilesDir.appendingPathComponent(newName)
        guard !itemExists(dst) else { throw ProfileError.profileExists(newName) }
        let wasActive = activeProfile() == name
        try fm.moveItem(at: src, to: dst)
        if wasActive { try pointClaudeDir(at: dst) } // keep the symlink valid
        return newName
    }

    /// Delete a profile — this is "logout": the account's login state is removed.
    /// The active profile can never be deleted (the symlink points at it).
    public func deleteProfile(name: String) throws {
        guard activeProfile() != name else { throw ProfileError.profileIsActive(name) }
        let dir = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(dir) else { throw ProfileError.profileNotFound(name) }
        try fm.removeItem(at: dir) // shared trees are symlinks inside it — shared history survives
    }

    /// Merge every profile's session trees into `_shared-sessions` and symlink them back.
    /// Returns the backup directory, or nil when there was nothing to migrate (idempotent re-run).
    @discardableResult
    public func enableSharedHistory(now: Date = Date()) throws -> URL? {
        let names = profiles()

        // Backup first: copy every real (not yet symlinked) session tree.
        var realTrees: [(profile: String, tree: String)] = []
        for profile in names {
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

        // Merge each profile tree into the shared tree, then symlink it back.
        for tree in Self.sessionTrees {
            let sharedTree = sharedDir.appendingPathComponent(tree)
            try fm.createDirectory(at: sharedTree, withIntermediateDirectories: true)
            for profile in names {
                let link = profilesDir.appendingPathComponent(profile).appendingPathComponent(tree)
                if isSymlink(link) { continue }
                if isRealDirectory(link) {
                    try merge(contentsOf: link, into: sharedTree)
                    try fm.removeItem(at: link)
                }
                // Missing trees get linked too, so future sessions land in the shared tree.
                try fm.createSymbolicLink(at: link, withDestinationURL: sharedTree)
            }
            try consolidateOrgDirs(in: sharedTree)
        }
        return backup
    }

    // MARK: - Internals

    /// Repoint the `Claude` symlink. Never deletes anything that is not a symlink.
    private func pointClaudeDir(at dest: URL) throws {
        switch claudeDirState() {
        case .missing:
            break
        case .symlink:
            try fm.removeItem(at: claudeDir) // removes the link itself, not the target
        case .realDirectory, .otherFile:
            throw ProfileError.refusedToClobber(claudeDir.path)
        }
        try fm.createSymbolicLink(at: claudeDir, withDestinationURL: dest)
    }

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

    /// Inside a shared tree, pick the <account>/<org> dir with the most files as master,
    /// merge every other real org dir into it, and symlink them to the master.
    private func consolidateOrgDirs(in tree: URL) throws {
        var orgDirs: [URL] = []
        for account in try realSubdirectories(of: tree) {
            orgDirs.append(contentsOf: try realSubdirectories(of: account))
        }
        guard orgDirs.count > 1 else { return }

        orgDirs.sort { $0.path < $1.path } // deterministic tie-break
        var master = orgDirs[0]
        var bestCount = fileCount(in: master)
        for dir in orgDirs.dropFirst() {
            let count = fileCount(in: dir)
            if count > bestCount { master = dir; bestCount = count }
        }
        for dir in orgDirs where dir != master {
            try merge(contentsOf: dir, into: master)
            try fm.removeItem(at: dir)
            try fm.createSymbolicLink(at: dir, withDestinationURL: master)
        }
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
