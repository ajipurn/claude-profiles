import SwiftUI
import ServiceManagement

@main
struct ClaudeProfilesApp: App {
    @StateObject private var state = AppState()

    init() {
        // The .app bundle sets LSUIElement; this covers `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.isSwitching ? "arrow.triangle.2.circlepath" : "person.crop.circle")
            Text(state.isSwitching ? "Switching…" : (state.activeProfile ?? "Claude"))
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if !state.claudeAppFound {
                Text("Claude.app not found in /Applications or ~/Applications")
            }
            switch state.mode {
            case .needsSetup:
                Button("Set up profiles…") { state.setUpProfiles() }
                    .disabled(!state.claudeAppFound || state.isSwitching)
            case .ready:
                if state.brokenLink {
                    Text("⚠️ Active profile is missing — switch to a profile to fix")
                }
                ForEach(state.profiles, id: \.self) { name in
                    if name == state.activeProfile {
                        Toggle(name, isOn: .constant(true)).disabled(true)
                    } else {
                        Button(name) { state.switchTo(name) }
                            .disabled(!state.claudeAppFound || state.isSwitching)
                    }
                }
                Divider()
                Button("New profile…") { state.newProfile() }
                    .disabled(!state.claudeAppFound || state.isSwitching)
                if !state.sharedHistoryEnabled {
                    Button("Share session history across profiles…") { state.enableSharedHistory() }
                        .disabled(!state.claudeAppFound || state.isSwitching)
                }
                if state.profiles.contains(where: { $0 != state.activeProfile }) {
                    Menu("Open in new window (experimental)") {
                        ForEach(state.profiles.filter { $0 != state.activeProfile }, id: \.self) { name in
                            Button(name) { state.openInNewWindow(name) }
                        }
                    }
                    .disabled(!state.claudeAppFound || state.isSwitching)
                }
            }
            Divider()
            Toggle("Launch at login", isOn: launchAtLogin)
            Button("Reveal profiles folder in Finder") { state.revealProfilesFolder() }
            Divider()
            Button("Quit Claude Profiles") { NSApp.terminate(nil) }
        }
        .onAppear { state.refresh() } // menu style re-evaluates content on open
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                do {
                    if enable { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("[Claude Profiles] Launch at login failed: %@", error.localizedDescription)
                }
            }
        )
    }
}
