import AppKit
import UserNotifications

/// Claude.app lifecycle: locate, quit, relaunch. No AppleScript — plain NSWorkspace,
/// so no Automation permission prompt.
@MainActor
final class ClaudeAppController {
    let appURL: URL?
    let bundleID: String?

    init() {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"),
        ]
        appURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        // Resolved from the bundle, not hardcoded (expected: com.anthropic.claudefordesktop).
        bundleID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Returns true when Claude ended up not running.
    func quit() async -> Bool {
        guard let bundleID else { return false }
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        guard !running.isEmpty else { return true }

        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return running.allSatisfy(\.isTerminated)
    }

    func relaunch() {
        guard let appURL else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Experimental: second instance on another profile. Claude may ignore the flag;
    /// failure is not an error state.
    func openNewWindow(profileDir: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", "Claude", "--args", "--user-data-dir=\(profileDir.path)"]
        try? process.run()
    }
}

enum Notifier {
    static func post(_ title: String, _ body: String = "") {
        // UNUserNotificationCenter requires a real .app bundle; `swift run` has none.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            NSLog("[Claude Profiles] %@ — %@", title, body)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return } // denied → degrade silently
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
