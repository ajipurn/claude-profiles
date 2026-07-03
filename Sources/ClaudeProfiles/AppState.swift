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

    func openInNewWindow(_ name: String) {
        claude.openNewWindow(profileDir: manager.profilesDir.appendingPathComponent(name))
        Notifier.post("Experimental", "If nothing opens for “\(name)”, Claude ignored --user-data-dir; use normal switching instead.")
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

    private func abortQuitFailed() {
        Notifier.post("Aborted", "Claude did not quit in time; nothing was changed.")
    }

    /// nil on cancel, empty/invalid name, or collision — caller does nothing (no partial state).
    private func promptForProfileName(title: String, message: String, defaultValue: String) -> String? {
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
        guard !profiles.contains(name) else {
            Notifier.post("Profile “\(name)” already exists")
            return nil
        }
        return name
    }
}
