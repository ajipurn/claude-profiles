import AppKit
import ServiceManagement

/// This is the last release: the app lives on as Agent Profiles, which reads
/// the same profiles. Offers to open (or download) it, then steps aside so
/// the two never switch accounts at the same time.
@MainActor
enum MoveToAgentProfiles {
    static let bundleID = "dev.aji.AgentProfiles"
    static let releasesURL = URL(string: "https://github.com/ajipurn/agent-profiles/releases/latest")!

    static var installedURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Asked at every launch; "Not Now" leaves this app working as before.
    static func offer(appName: String) {
        let alert = NSAlert()
        alert.messageText = "\(appName) is now Agent Profiles"
        alert.informativeText = "Claude Profiles and Codex Profiles are one app now: Agent Profiles, "
            + "with both providers in one menu. It uses the profiles you already have, so nothing "
            + "needs setting up again. \(appName) gets no more updates."
        alert.addButton(withTitle: installedURL == nil ? "Download Agent Profiles" : "Open Agent Profiles")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        move()
    }

    static func move() {
        guard installedURL != nil else {
            NSWorkspace.shared.open(releasesURL)
            return
        }
        // Launch at login would start both apps next time.
        try? SMAppService.mainApp.unregister()
        // Start Agent Profiles only after this app has quit; it refuses to
        // run next to it. A detached `open` outlives this process.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", "sleep 1; /usr/bin/open -b \(bundleID)"]
        try? opener.run()
        NSApp.terminate(nil)
    }
}
