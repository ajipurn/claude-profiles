import AppKit
import Combine
import ClaudeProfilesCore

@MainActor
final class AppState: ObservableObject {
    enum Mode { case needsSetup, ready }

    let manager = ProfileManager()
    let claude = ClaudeAppController()

    @Published var profiles: [String] = []
    @Published var activeProfile: String?
    @Published var mode: Mode = .ready
    @Published var brokenLink = false
    @Published var sharedHistoryEnabled = false
    @Published var isSwitching = false

    var claudeAppFound: Bool { claude.appURL != nil }

    init() { refresh() }

    func refresh() {
        profiles = manager.profiles()
        activeProfile = manager.activeProfile()
        sharedHistoryEnabled = manager.sharedHistoryEnabled
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
                try self.manager.switchTo(name: name)
                Notifier.post("Switched to \(name)")
            } catch {
                Notifier.post("Switch failed", error.localizedDescription)
            }
            self.claude.relaunch()
        }
    }

    func newProfile() {
        guard let name = promptForProfileName(
            title: "New profile",
            message: "Name for the new account profile.",
            defaultValue: ""
        ) else { return }
        run {
            do {
                try self.manager.createProfile(name: name)
            } catch {
                return Notifier.post("Could not create profile", error.localizedDescription)
            }
            guard await self.claude.quit() else { return self.abortQuitFailed() }
            self.relinkSharedHistoryIfEnabled()
            do {
                try self.manager.switchTo(name: name)
                self.claude.relaunch()
                Notifier.post("Profile “\(name)” created",
                              "Log in once in the window that opens — never again after that.")
            } catch {
                Notifier.post("Switch failed", error.localizedDescription)
            }
        }
    }

    func renameProfile(_ name: String) {
        guard let newName = promptForProfileName(
            title: "Rename profile",
            message: "New name for “\(name)”.",
            defaultValue: name,
            allowing: name
        ), newName != name else { return }
        if manager.activeProfile() == name {
            // Active profile: the symlink must be repointed, so Claude has to quit.
            run {
                guard await self.claude.quit() else { return self.abortQuitFailed() }
                do {
                    try self.manager.renameProfile(name, to: newName)
                    Notifier.post("Renamed to “\(newName)”")
                } catch {
                    Notifier.post("Rename failed", error.localizedDescription)
                }
                self.claude.relaunch()
            }
        } else {
            do {
                try manager.renameProfile(name, to: newName)
                Notifier.post("Renamed to “\(newName)”")
            } catch {
                Notifier.post("Rename failed", error.localizedDescription)
            }
            refresh()
        }
    }

    func deleteProfile(_ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete profile “\(name)”?"
        alert.informativeText = "This logs the account out by deleting its data. You would need to log in again next time. "
            + (sharedHistoryEnabled
               ? "The shared session history is kept."
               : "Its session history is deleted with it.")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try manager.deleteProfile(name: name)
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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

    func revealProfilesFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([manager.profilesDir])
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
    private func promptForProfileName(title: String, message: String, defaultValue: String, allowing: String? = nil) -> String? {
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
        guard !profiles.contains(name) || name == allowing else {
            Notifier.post("Profile “\(name)” already exists")
            return nil
        }
        return name
    }
}
