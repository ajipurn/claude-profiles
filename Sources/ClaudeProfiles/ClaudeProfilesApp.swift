import SwiftUI
import ServiceManagement

let accent = Color(red: 0.85, green: 0.47, blue: 0.34) // matches the app icon

@main
struct ClaudeProfilesApp: App {
    @StateObject private var state = AppState()

    init() {
        // The .app bundle sets LSUIElement; this covers `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 20, height: 20)
        return image // full-color; the dark outline reads fine in both menu bar modes
    }()

    var body: some Scene {
        MenuBarExtra {
            PanelView(state: state)
        } label: {
            if state.isSwitching {
                Image(systemName: "arrow.triangle.2.circlepath")
            } else if let icon = Self.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "person.crop.circle") // `swift run` has no bundle resources
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !state.claudeAppFound {
                Banner(icon: "exclamationmark.triangle.fill",
                       text: "Claude.app not found in /Applications or ~/Applications")
            }
            switch state.mode {
            case .needsSetup:
                SetupView(state: state)
            case .ready:
                if state.brokenLink {
                    Banner(icon: "link.badge.plus",
                           text: "Active profile is missing — pick a profile to fix it")
                }
                HStack(spacing: 0) {
                    SectionLabel("Profiles")
                    Spacer(minLength: 0)
                    if state.cliSetUp {
                        IconButton(systemName: "questionmark.circle", help: "CLI terminal setup") {
                            state.showCLIPathHelp()
                        }
                        .padding(.trailing, 6)
                    }
                }
                if state.cliSetUp && !state.cliDefaultHidden {
                    // The CLI's default account: plain ~/.claude, no Desktop side.
                    ProfileRow(name: "Default",
                               hasDesktop: false, hasCLI: true,
                               desktopActive: false,
                               cliActive: state.activeCLIProfile == nil,
                               disabled: false,
                               onDesktop: nil,
                               onCLI: { state.switchCLI(nil) },
                               onDelete: { state.hideDefaultRow() },
                               deleteIcon: "eye.slash",
                               deleteHelp: "Hide (nothing is deleted)")
                }
                ForEach(state.allProfiles, id: \.self) { name in
                    ProfileRow(
                        name: name,
                        hasDesktop: state.profiles.contains(name),
                        hasCLI: state.cliCreated.contains(name),
                        desktopActive: name == state.activeProfile,
                        cliActive: name == state.activeCLIProfile,
                        disabled: !state.claudeAppFound || state.isSwitching,
                        onDesktop: { state.switchTo(name) },
                        onCLI: state.cliSetUp ? { state.switchCLI(name) } : nil,
                        onRename: { state.renameProfile(name) },
                        onDelete: name == state.activeProfile ? nil : { state.deleteProfile(name) }
                    )
                }
                ActionRow(icon: "plus.circle.fill", title: "New Profile", tint: accent,
                          disabled: !state.claudeAppFound || state.isSwitching) {
                    state.newProfile()
                }
                if !state.cliSetUp {
                    ActionRow(icon: "terminal", title: "Set Up CLI Profiles…") {
                        state.setUpCLIProfiles()
                    }
                }
                PanelDivider()
                if !state.sharedHistoryEnabled {
                    ActionRow(icon: "clock.arrow.2.circlepath", title: "Share Session History…",
                              disabled: !state.claudeAppFound || state.isSwitching) {
                        state.enableSharedHistory()
                    }
                }
                LaunchAtLoginRow()
                ActionRow(icon: "folder", title: "Reveal Profiles in Finder") {
                    state.revealProfilesFolder()
                }
            }
            PanelDivider()
            ActionRow(icon: "power", title: "Quit Claude Profiles") {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 280)
        .onAppear { state.refresh() }
    }
}

// MARK: - Rows

/// One row per profile, tagged per context: the window icon is Claude Desktop,
/// the terminal icon is claude CLI. At rest a row shows only its *active* tags
/// (accent); hovering reveals both switch buttons — same pattern as the
/// rename/delete actions, so the list stays quiet.
struct ProfileRow: View {
    let name: String
    let hasDesktop: Bool
    let hasCLI: Bool
    let desktopActive: Bool
    let cliActive: Bool
    let disabled: Bool
    let onDesktop: (() -> Void)?
    let onCLI: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var deleteIcon = "trash"
    var deleteHelp = "Delete (logout)"
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Row click keeps the old meaning: switch Desktop (or CLI for
            // rows that have no Desktop side, like Default).
            Button(action: { (onDesktop ?? onCLI)?() }) {
                HStack(spacing: 8) {
                    // Desktop is the row's primary identity — CLI-active alone
                    // shows only the accent terminal tag, keeping hierarchy clear.
                    Avatar(name: name, active: desktopActive)
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(onDesktop != nil ? (disabled || desktopActive) : cliActive)

            if hovering && !disabled {
                if let onRename {
                    IconButton(systemName: "pencil", help: "Rename", action: onRename)
                }
                if let onDelete {
                    IconButton(systemName: deleteIcon, help: deleteHelp, action: onDelete)
                }
            }
            if let onDesktop, desktopActive || (hovering && !disabled) {
                ContextIcon(systemName: "macwindow",
                            active: desktopActive, present: hasDesktop, disabled: disabled,
                            help: desktopActive ? "Active in Claude Desktop"
                                : hasDesktop ? "Use in Claude Desktop"
                                : "Use in Claude Desktop (logs in once)",
                            action: onDesktop)
            }
            if let onCLI, cliActive || hovering {
                ContextIcon(systemName: "terminal",
                            active: cliActive, present: hasCLI, disabled: false,
                            help: cliActive ? "Active for claude in the terminal"
                                : hasCLI ? "Use for claude in the terminal — instant"
                                : "Use for claude in the terminal (logs in once)",
                            action: onCLI)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(desktopActive ? accent.opacity(0.13)
                      : hovering ? Color.primary.opacity(0.06)
                      : .clear)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The per-context tag + switch button on a profile row.
struct ContextIcon: View {
    let systemName: String
    let active: Bool
    let present: Bool
    let disabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(accent)
                    : hovering ? AnyShapeStyle(Color.primary)
                    : AnyShapeStyle(Color.secondary.opacity(present ? 0.9 : 0.5)))
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? accent.opacity(0.15)
                    : hovering ? Color.primary.opacity(0.1)
                    : .clear))
        }
        .buttonStyle(PressableStyle())
        .disabled(active || disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

struct ActionRow: View {
    let icon: String
    let title: String
    var tint: Color = .primary
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint == .primary ? Color.secondary : tint)
                    .frame(width: 18)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering && !disabled ? Color.primary.opacity(0.06) : .clear)
            )
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct LaunchAtLoginRow: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .frame(width: 18)
            Toggle("Launch at Login", isOn: $enabled)
                .toggleStyle(.checkbox)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .onChange(of: enabled) { on in
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("[Claude Profiles] Launch at login failed: %@", error.localizedDescription)
                enabled = SMAppService.mainApp.status == .enabled
            }
        }
    }
}

// MARK: - Pieces

struct Avatar: View {
    let name: String
    let active: Bool

    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
    }

    var body: some View {
        ZStack {
            Circle().fill(
                active
                ? AnyShapeStyle(LinearGradient(colors: [accent, accent.opacity(0.7)],
                                               startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(Color(hue: hue, saturation: 0.35, brightness: 0.75).opacity(0.85))
            )
            Text(String(name.prefix(2)).uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 18, height: 18)
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

struct Banner: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.orange)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.1)))
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(accent)
            Text("One directory per account,\nswitch without ever logging in again.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Set Up Profiles…") { state.setUpProfiles() }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!state.claudeAppFound || state.isSwitching)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

struct PanelDivider: View {
    var body: some View {
        Divider().padding(.vertical, 3).padding(.horizontal, 4)
    }
}

/// Press feedback: subtle scale, fast ease-out. Never from scale(0), never slow.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
