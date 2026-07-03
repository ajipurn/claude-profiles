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
                SectionLabel("Profiles")
                ForEach(state.profiles, id: \.self) { name in
                    ProfileRow(
                        name: name,
                        isActive: name == state.activeProfile,
                        disabled: !state.claudeAppFound || state.isSwitching,
                        onSwitch: { state.switchTo(name) },
                        onRename: { state.renameProfile(name) },
                        onDelete: { state.deleteProfile(name) }
                    )
                }
                ActionRow(icon: "plus.circle.fill", title: "New Profile", tint: accent,
                          disabled: !state.claudeAppFound || state.isSwitching) {
                    state.newProfile()
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

struct ProfileRow: View {
    let name: String
    let isActive: Bool
    let disabled: Bool
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { if !isActive { onSwitch() } }) {
                HStack(spacing: 8) {
                    Avatar(name: name, active: isActive)
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(disabled || isActive)

            if hovering && !disabled {
                IconButton(systemName: "pencil", help: "Rename", action: onRename)
                if !isActive {
                    IconButton(systemName: "trash", help: "Delete (logout)", action: onDelete)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? accent.opacity(0.13)
                      : hovering ? Color.primary.opacity(0.06)
                      : .clear)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
