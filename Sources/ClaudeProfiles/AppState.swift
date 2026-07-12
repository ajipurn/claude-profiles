import AppKit
import Combine
import ClaudeProfilesCore

@MainActor
final class AppState: ObservableObject {
    enum Mode { case needsSetup, ready }

    let manager = ProfileManager()
    let cli = CLIProfileManager()
    let claude = ClaudeAppController()

    @Published var profiles: [String] = []
    @Published var activeProfile: String?
    @Published var mode: Mode = .ready
    @Published var brokenLink = false
    @Published var sharedHistoryEnabled = false
    @Published var isSwitching = false
    @Published var allProfiles: [String] = []   // one list: every name, Desktop and/or CLI
    @Published var cliCreated: Set<String> = [] // names that have a CLI config dir
    @Published var activeCLIProfile: String?    // nil = default ~/.claude
    @Published var cliSetUp = false
    @Published var cliDefaultHidden = false
    @Published var usage: [String: ProfileUsage] = [:] // per Desktop profile
    @Published var usageScanRunning = false
    @Published var lastUsageScan: Date?

    var claudeAppFound: Bool { claude.appURL != nil }

    /// The panel's refresh button and the status-item menu both live outside
    /// any SwiftUI scene, so opening the main window goes through this hook
    /// (set by the app delegate) instead of @Environment(\.openWindow).
    var openWindowHandler: (() -> Void)?

    init() {
        // Absolute symlinks from older versions break Cowork's VM (it resolves
        // them against the guest root). One-time rewrite to relative targets.
        try? manager.makeSymlinksRelative()
        refresh()
        // The usage scan is async, so the menu bar's first frame used to
        // flash the no-data fallback icon. Reading just the active profile's
        // cache here (a handful of small files) keeps launch on the gauge.
        if let active = activeProfile, let u = manager.usage(profile: active) {
            usage[active] = u
        }
        // Scripts in _cli/bin were written by whichever app version ran setup;
        // rewriting them at launch keeps older installs current (idempotent).
        if cli.isSetUp { try? cli.installShim() }
        // A new account's session dirs join the combined list only when the merge
        // re-runs, and that is only safe while Claude is not running. Besides the
        // switch flow, catch the two other moments Claude is known to be down:
        // whenever it terminates, and at our own launch.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let app,
                      app.bundleIdentifier == self.claude.bundleID,
                      !self.isSwitching else { return }
                self.relinkSharedHistoryIfEnabled()
                self.refresh()
            }
        }
        if !claude.isRunning { relinkSharedHistoryIfEnabled() }
        // The menu bar shows the active account's remaining 5-hour limit;
        // Claude refreshes its cached numbers as it runs, so poll them.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshUsage() }
        }
    }

    func refresh() {
        // Symlink-only, so safe even while Claude runs — a freshly logged-in
        // account joins the combined list the next time the panel opens.
        // Claude's sidebar is already in memory, so new links need one restart.
        if let linked = try? manager.prelinkKnownAccounts(), linked > 0, claude.isRunning {
            Notifier.post("Session history linked",
                          "Quit and reopen Claude once to see the combined list.")
        }
        profiles = manager.profiles()
        activeProfile = manager.activeProfile()
        sharedHistoryEnabled = manager.sharedHistoryEnabled
        // One list for both worlds. A profile is "tagged" for a context once its
        // dir exists there; dirs are created on first use. The *login* can never
        // carry over — Desktop and CLI have separate auth — so each context
        // still asks to log in once.
        cliCreated = Set(cli.profiles())
        allProfiles = manager.ordered(Array(cliCreated.union(profiles)))
        activeCLIProfile = cli.activeProfile()
        cliSetUp = cli.isSetUp
        cliDefaultHidden = cli.defaultHidden
        let state = manager.claudeDirState()
        if case .symlink(_, false) = state { brokenLink = true } else { brokenLink = false }
        switch state {
        case .realDirectory:
            mode = .needsSetup
        case .missing:
            mode = profiles.isEmpty ? .needsSetup : .ready
        default:
            mode = .ready
        }
        refreshUsage()
        watchActiveProfileCache()
    }

    // MARK: - Cache watcher

    private var cacheWatcher: DispatchSourceFileSystemObject?
    private var watchedCachePath: String?
    private var watchDebounce: DispatchWorkItem?

    /// Kicks a usage rescan whenever Claude writes into the active profile's
    /// HTTP cache directory, so the menu bar tracks in near-realtime instead
    /// of waiting out the 60-second poll (which stays as the fallback — file
    /// rewrites that don't touch the directory entry go unseen here).
    private func watchActiveProfileCache() {
        let path = activeProfile.map {
            manager.profilesDir.appendingPathComponent($0)
                .appendingPathComponent("Cache/Cache_Data").path
        }
        guard path != watchedCachePath else { return }
        cacheWatcher?.cancel()
        cacheWatcher = nil
        watchedCachePath = path
        guard let path else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            watchedCachePath = nil // dir not there yet (never logged in) — retry next refresh
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Chromium writes entries in bursts; scan once things settle.
            self.watchDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in self?.refreshUsage() }
            }
            self.watchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        cacheWatcher = source
    }

    /// Scans every profile's cache off the main thread; cheap (small files
    /// only) but not free, so runs are coalesced.
    func refreshUsage() {
        guard !usageScanRunning else { return }
        usageScanRunning = true
        let names = profiles
        let manager = manager
        Task.detached(priority: .utility) {
            // One task per profile: the scans are independent file reads.
            let map = await withTaskGroup(of: (String, ProfileUsage?).self) { group in
                for name in names {
                    group.addTask { (name, manager.usage(profile: name)) }
                }
                var out: [String: ProfileUsage] = [:]
                for await (name, usage) in group {
                    if let usage { out[name] = usage }
                }
                return out
            }
            await MainActor.run {
                self.usage = map
                self.usageScanRunning = false
                self.lastUsageScan = Date()
                self.notifyIfActiveNearlyOut()
            }
        }
    }

    // Windows already alerted about, keyed by profile + reset time so each
    // 5-hour window fires at most once. In-memory on purpose: a relaunch
    // re-alerting once is fine.
    private var lowLimitNotified: Set<String> = []

    /// Posts one notification when the active profile's 5-hour window enters
    /// the red zone (≤10% left), suggesting the freshest other profile;
    /// clicking the notification switches to it (handled in the app delegate).
    private func notifyIfActiveNearlyOut() {
        guard let active = activeProfile,
              let window = usage[active]?.fiveHour, !window.expired,
              let resetsAt = window.resetsAt else { return }
        let remaining = window.remainingPercent
        guard remaining <= 10 else { return }
        let key = "\(active)-\(Int(resetsAt.timeIntervalSince1970))"
        guard !lowLimitNotified.contains(key) else { return }
        lowLimitNotified.insert(key)

        // Best candidate: the other profile with the most 5h left — only
        // suggested when comfortably green, otherwise the alert stands alone.
        var bestName: String?
        var bestRemaining = 40
        for name in allProfiles where name != active {
            if let r = usage[name]?.fiveHourRemaining, r > bestRemaining {
                bestName = name
                bestRemaining = r
            }
        }
        let resets = RelativeDateTimeFormatter().localizedString(for: resetsAt, relativeTo: Date())
        if let bestName {
            Notifier.post("\(active) is nearly out — \(remaining)% of 5h left",
                          "Resets \(resets). Click to switch to \(bestName) (\(bestRemaining)% left).",
                          userInfo: ["switchTo": bestName])
        } else {
            Notifier.post("\(active) is nearly out — \(remaining)% of 5h left",
                          "Resets \(resets).")
        }
    }

    // MARK: - Actions

    func setUpProfiles() {
        guard let name = promptForProfileName(
            title: "Set up profiles",
            message: "Name for the currently logged-in Claude account.",
            defaultValue: "main"
        ) else { return }
        run {
            guard await self.claude.quit() else { return self.abortQuitFailed() }
            do {
                try self.manager.migrate(name: name)
                self.claude.relaunch()
                Notifier.post("Profiles enabled", "Current account saved as “\(name)”.")
            } catch {
                Notifier.post("Setup failed", error.localizedDescription)
            }
        }
    }

    func switchTo(_ name: String) {
        run {
            guard await self.claude.quit() else { return self.abortQuitFailed() }
            self.relinkSharedHistoryIfEnabled()
            do {
                if !self.manager.profiles().contains(name) {
                    try self.manager.createProfile(name: name) // CLI-only name used for Desktop — dir on demand
                }
                try self.manager.switchTo(name: name)
                Notifier.post("Switched to \(name)")
            } catch {
                Notifier.post("Switch failed", error.localizedDescription)
            }
            self.claude.relaunch()
            // A profile that has never logged in can't be prelinked yet (its
            // account/org ids don't exist until Claude writes them at login) —
            // watch for the ids so the combined sidebar needs no detour.
            if self.sharedHistoryEnabled, !self.manager.hasAccountIDs(profile: name) {
                self.watchForFirstLogin(of: name)
            }
        }
    }

    // MARK: - First-login watcher

    private var loginWatcher: Timer?

    /// Polls the active profile until Claude writes its login ids, then links
    /// its org dir into the shared tree and offers the one restart Claude
    /// needs to load the combined sidebar. Ends on switch-away or after ~15 min.
    private func watchForFirstLogin(of name: String) {
        loginWatcher?.invalidate()
        var ticks = 0
        loginWatcher = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                ticks += 1
                guard ticks <= 300, self.manager.activeProfile() == name else {
                    timer.invalidate()
                    return
                }
                guard self.manager.hasAccountIDs(profile: name) else { return }
                timer.invalidate()
                let linked = (try? self.manager.prelinkKnownAccounts()) ?? 0
                if linked > 0 { self.offerHistoryRestart(name) }
            }
        }
    }

    private func offerHistoryRestart(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Load the shared history?"
        alert.informativeText = "“\(name)” just logged in. Claude loads its sidebar at startup, "
            + "so one quick restart is needed to show the combined session list."
        alert.addButton(withTitle: "Restart Claude")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            Notifier.post("Session history linked",
                          "Quit and reopen Claude whenever you like to see the combined list.")
            return
        }
        run {
            guard await self.claude.quit() else { return self.abortQuitFailed() }
            self.claude.relaunch()
        }
    }

    /// Creating a profile is just a folder — it never touches the running session.
    /// The login happens on the first switch to it.
    func newProfile() {
        guard let name = promptForProfileName(
            title: "New profile",
            message: "Name for the new account profile.",
            defaultValue: "",
            existing: allProfiles
        ) else { return }
        do {
            try manager.createProfile(name: name)
            try? manager.saveOrder(manager.savedOrder().filter { $0 != name } + [name])
            Notifier.post("Profile “\(name)” created",
                          "Use it for Desktop or CLI whenever you're ready — each logs in once, then never again.")
        } catch {
            Notifier.post("Could not create profile", error.localizedDescription)
        }
        refresh()
    }

    /// Persist the current list order after a drag-reorder. The drop delegate
    /// already reordered `allProfiles` live; this writes it to disk.
    func saveProfileOrder() {
        try? manager.saveOrder(allProfiles)
    }

    /// Renames a profile everywhere it exists, so the row never splits in two.
    /// The CLI side cannot survive a rename (its path is the Keychain identity),
    /// so the user is warned that it will be logged out.
    func renameProfile(_ name: String) {
        guard let newName = promptForProfileName(
            title: "Rename profile",
            message: "New name for “\(name)”.",
            defaultValue: name,
            existing: allProfiles,
            allowing: name
        ), newName != name else { return }
        let hasDesktop = profiles.contains(name)
        let hasCLI = cliCreated.contains(name)
        if hasCLI {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Rename logs the CLI side out"
            alert.informativeText = "Claude Code ties this profile's terminal login to its folder path. "
                + "After renaming, the next `claude` run asks you to log in once again. "
                + (hasDesktop ? "The Desktop login is kept." : "")
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let renameCLI = { @MainActor in
            guard hasCLI else { return }
            do { try self.cli.renameProfile(name, to: newName) }
            catch { Notifier.post("CLI rename failed", error.localizedDescription) }
        }
        if hasDesktop, manager.activeProfile() == name {
            // Active Desktop profile: the symlink must be repointed, so Claude has to quit.
            run {
                guard await self.claude.quit() else { return self.abortQuitFailed() }
                do {
                    try self.manager.renameProfile(name, to: newName)
                    renameCLI()
                    try? self.manager.saveOrder(self.manager.savedOrder().map { $0 == name ? newName : $0 })
                    Notifier.post("Renamed to “\(newName)”")
                } catch {
                    Notifier.post("Rename failed", error.localizedDescription)
                }
                self.claude.relaunch()
            }
        } else {
            do {
                if hasDesktop { try manager.renameProfile(name, to: newName) }
                renameCLI()
                try? manager.saveOrder(manager.savedOrder().map { $0 == name ? newName : $0 })
                Notifier.post("Renamed to “\(newName)”")
            } catch {
                Notifier.post("Rename failed", error.localizedDescription)
            }
            refresh()
        }
    }

    /// Deletes the profile everywhere it exists — Desktop (= logout) and CLI data.
    func deleteProfile(_ name: String) {
        let hasDesktop = profiles.contains(name)
        let hasCLI = cliCreated.contains(name)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete profile “\(name)”?"
        var info = "This logs the account out by deleting its data. You would need to log in again next time. "
        if hasDesktop {
            info += sharedHistoryEnabled
                ? "The shared session history is kept. "
                : "Its session history is deleted with it. "
        }
        if hasCLI {
            info += "Its CLI login token stays in your Keychain until you remove it yourself (Keychain Access)."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if hasDesktop { try manager.deleteProfile(name: name) } // throws if active
            if hasCLI { try cli.deleteProfile(name: name) }
            try? manager.saveOrder(manager.savedOrder().filter { $0 != name })
            Notifier.post("Profile “\(name)” deleted")
        } catch {
            Notifier.post("Delete failed", error.localizedDescription)
        }
        refresh()
    }

    func enableSharedHistory() {
        let alert = NSAlert()
        alert.messageText = "Share session history across profiles?"
        alert.informativeText = "This merges all profiles' session history into one shared list. A timestamped backup is created in your home folder first."
        alert.addButton(withTitle: "Merge & Share")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        // refresh() on cancel snaps the Settings toggle back to reality.
        guard alert.runModal() == .alertFirstButtonReturn else { refresh(); return }
        run {
            guard await self.claude.quit() else { return self.abortQuitFailed() }
            do {
                let backup = try self.manager.enableSharedHistory()
                self.claude.relaunch()
                Notifier.post("Shared history enabled",
                              backup.map { "Backup: \($0.path)" } ?? "Was already enabled.")
            } catch {
                self.claude.relaunch()
                Notifier.post("Sharing failed", error.localizedDescription)
            }
        }
    }

    /// The reverse of sharing: every profile keeps a copy of the combined
    /// history, new sessions stay per-profile. Needs Claude down, like enable.
    func disableSharedHistory() {
        let alert = NSAlert()
        alert.messageText = "Stop sharing session history?"
        alert.informativeText = "Every profile keeps its own copy of the combined history — nothing is lost, "
            + "but the copies grow independently from now on. Claude will restart."
        alert.addButton(withTitle: "Stop Sharing")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { refresh(); return }
        run {
            guard await self.claude.quit() else { return self.abortQuitFailed() }
            do {
                try self.manager.disableSharedHistory()
                self.claude.relaunch()
                Notifier.post("Shared history disabled", "Each profile now has its own copy.")
            } catch {
                self.claude.relaunch()
                Notifier.post("Disabling failed", error.localizedDescription)
            }
        }
    }

    /// Toggle in Settings — no alert: a labeled toggle explains itself,
    /// and it is UI-only (nothing is deleted either way).
    func setDefaultRowHidden(_ hidden: Bool) {
        do { try cli.setDefaultHidden(hidden) }
        catch { Notifier.post("Could not update", error.localizedDescription) }
        refresh()
    }

    func revealProfilesFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([manager.profilesDir])
    }

    // MARK: - CLI profiles

    /// Instant: no quit, no relaunch. Applies to `claude` commands started
    /// from now on — running terminal sessions keep their account.
    func switchCLI(_ name: String?) {
        do {
            var firstTime = false
            if let name, !cliCreated.contains(name) {
                try cli.createProfile(name: name) // mirrored Desktop name — dir on demand
                firstTime = true
            }
            try cli.setActive(name)
            Notifier.post("CLI: \(name ?? "Default") selected",
                          firstTime
                          ? "Run claude in a new terminal — it asks you to log in once."
                          : "Applies to claude commands you start from now on.")
        } catch {
            Notifier.post("CLI switch failed", error.localizedDescription)
        }
        refresh()
    }

    func setUpCLIProfiles() {
        do {
            try cli.installShim()
        } catch {
            Notifier.post("CLI setup failed", error.localizedDescription)
            return
        }
        refresh()
        showCLIPathHelp(firstTime: true)
    }

    /// Hiding is UI-only: the ~/.claude account keeps working as the fallback,
    /// nothing is deleted, and the row can come back from the ? dialog.
    func hideDefaultRow() {
        let alert = NSAlert()
        alert.messageText = "Hide the Default profile?"
        alert.informativeText = "Default is your original ~/.claude account — the one claude used before profiles, "
            + "with all its settings and plugins. Hiding only removes this row; nothing is deleted"
            + (activeCLIProfile == nil ? ", and terminal commands keep using it until you pick another profile" : "")
            + ". Bring it back anytime via the ? button."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try cli.setDefaultHidden(true) }
        catch { Notifier.post("Could not hide Default", error.localizedDescription) }
        refresh()
    }

    /// The shim only takes effect once its bin dir is on PATH — one manual
    /// ~/.zshrc line. Editing the user's shell config is not this app's place.
    func showCLIPathHelp(firstTime: Bool = false) {
        let alert = NSAlert()
        alert.messageText = firstTime ? "One last step" : "CLI profiles — terminal setup"
        alert.informativeText = "Add this line to the end of ~/.zshrc, then open a new terminal:\n\n"
            + CLIProfileManager.pathLine + "\n\n"
            + "After that, every `claude` command uses whichever profile is selected here. "
            + "Your own aliases and CLAUDE_CONFIG_DIR always take priority."
        alert.addButton(withTitle: "Copy Line")
        alert.addButton(withTitle: "Done")
        if cliDefaultHidden {
            alert.addButton(withTitle: "Show Default Row")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(CLIProfileManager.pathLine, forType: .string)
        case .alertThirdButtonReturn:
            try? cli.setDefaultHidden(false)
            refresh()
        default:
            break
        }
    }

    // MARK: - Helpers

    private func run(_ body: @escaping () async -> Void) {
        guard !isSwitching else { return }
        isSwitching = true
        Task {
            await body()
            self.isSwitching = false
            self.refresh()
        }
    }

    /// Accounts that log in after shared history was enabled create fresh
    /// <account>/<org> dirs inside the shared trees. Re-running the idempotent
    /// merge links them to the master — only safe while Claude is quit, which
    /// is why this runs during switches and not on a timer.
    private func relinkSharedHistoryIfEnabled() {
        guard manager.sharedHistoryEnabled else { return }
        do { try manager.enableSharedHistory() }
        catch { Notifier.post("Session re-link failed", error.localizedDescription) }
    }

    private func abortQuitFailed() {
        Notifier.post("Aborted", "Claude did not quit in time; nothing was changed.")
    }

    /// nil on cancel, empty/invalid name, or collision — caller does nothing (no partial state).
    /// `allowing` exempts one name from the collision check (rename to itself).
    private func promptForProfileName(title: String, message: String, defaultValue: String,
                                      existing: [String]? = nil, allowing: String? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultValue
        field.placeholderString = "letters, digits, - and _"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let name = ProfileManager.sanitize(field.stringValue) else { return nil }
        guard !(existing ?? profiles).contains(name) || name == allowing else {
            Notifier.post("Profile “\(name)” already exists")
            return nil
        }
        return name
    }
}
