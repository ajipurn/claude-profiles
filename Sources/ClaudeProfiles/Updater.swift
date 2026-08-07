import AppKit
import Sparkle
import SwiftUI

/// Thin Sparkle wrapper: scheduled background checks plus a manual "Check Now",
/// with the full download → verify → install → relaunch flow handled by
/// Sparkle's standard UI. The feed URL and public EdDSA key live in Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`); this only owns the controller and mirrors the
/// Settings toggle.
///
/// Nil unless the app runs from a real `.app` bundle with a public key set —
/// Sparkle needs both, and `swift run` has neither, so we simply don't start it.
@MainActor
final class Updater {
    static let shared: Updater? = {
        guard Bundle.main.bundleURL.pathExtension == "app",
              (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
        else { return nil }
        return Updater()
    }()

    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true starts the scheduled-check timer right away;
        // interval and opt-in come from Info.plist / the toggle below.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Two-way binding for the Settings toggle — Sparkle persists this itself.
    var automaticChecks: Binding<Bool> {
        Binding(get: { self.controller.updater.automaticallyChecksForUpdates },
                set: { self.controller.updater.automaticallyChecksForUpdates = $0 })
    }

    /// Manual check. Activates first: a menu-bar (accessory) app must come
    /// forward or Sparkle's dialog opens behind everything.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}
