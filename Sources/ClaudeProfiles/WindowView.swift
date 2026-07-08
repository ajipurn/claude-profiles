import SwiftUI
import ClaudeProfilesCore

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let githubURL = URL(string: "https://github.com/ajipurn/claude-profiles")!

/// The panel's content, redesigned for a regular window: same visual language
/// (avatars, accent, quiet hover reveals), more air. Context switches become
/// always-visible labeled chips — a window can afford permanent affordances
/// where the panel hides them behind hover.
struct WindowView: View {
    @ObservedObject var state: AppState
    @AppStorage("profileViewMode") private var viewMode = ViewMode.list
    @State private var showAbout = false

    enum ViewMode: String { case list, grid }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !state.claudeAppFound {
                Banner(icon: "exclamationmark.triangle.fill",
                       text: "Claude.app not found in /Applications or ~/Applications")
            }
            switch state.mode {
            case .needsSetup:
                SetupView(state: state)
                Spacer(minLength: 0)
            case .ready:
                if state.brokenLink {
                    Banner(icon: "link.badge.plus",
                           text: "Active profile is missing — pick a profile to fix it")
                }
                profilesHeader
                ScrollView {
                    if viewMode == .list { profileList } else { profileGrid }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                optionsSection
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity,
               minHeight: 440, idealHeight: 660, maxHeight: .infinity)
        .onAppear { state.refresh() }
        .sheet(isPresented: $showAbout) { AboutView() }
    }

    private var profilesHeader: some View {
        HStack(spacing: 8) {
            SectionLabel("Profiles · \(state.allProfiles.count)")
            Spacer()
            Picker("View", selection: $viewMode) {
                Image(systemName: "list.bullet").tag(ViewMode.list)
                    .help("List view")
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                    .help("Grid view")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 70)
            Button {
                state.newProfile()
            } label: {
                Label("New Profile", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!state.claudeAppFound || state.isSwitching)
        }
    }

    // MARK: Profiles — list

    private var profileList: some View {
        LazyVStack(spacing: 2) {
            if state.cliSetUp && !state.cliDefaultHidden {
                WindowProfileRow(name: "Default",
                                 subtitle: "the original ~/.claude account",
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
                WindowProfileRow(
                    name: name,
                    subtitle: nil,
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
        }
        .padding(6)
    }

    // MARK: Profiles — grid

    private var profileGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
            if state.cliSetUp && !state.cliDefaultHidden {
                WindowProfileCard(name: "Default",
                                  hasDesktop: false, hasCLI: true,
                                  desktopActive: false,
                                  cliActive: state.activeCLIProfile == nil,
                                  disabled: false,
                                  onDesktop: nil,
                                  onCLI: { state.switchCLI(nil) },
                                  onDelete: { state.hideDefaultRow() },
                                  deleteLabel: "Hide")
            }
            ForEach(state.allProfiles, id: \.self) { name in
                WindowProfileCard(
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
        }
        .padding(8)
    }

    // MARK: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Options")
            GroupBoxList {
                if !state.sharedHistoryEnabled {
                    ActionRow(icon: "clock.arrow.2.circlepath", title: "Share Session History…",
                              disabled: !state.claudeAppFound || state.isSwitching) {
                        state.enableSharedHistory()
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 18)
                        Text("Session history is shared across profiles")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                }
                if !state.cliSetUp {
                    ActionRow(icon: "terminal", title: "Set Up CLI Profiles…") {
                        state.setUpCLIProfiles()
                    }
                } else {
                    ActionRow(icon: "questionmark.circle", title: "CLI Terminal Setup…") {
                        state.showCLIPathHelp()
                    }
                }
                LaunchAtLoginRow()
                ActionRow(icon: "folder", title: "Reveal Profiles in Finder") {
                    state.revealProfilesFolder()
                }
                ActionRow(icon: "info.circle", title: "About & Updates…") {
                    showAbout = true
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("Claude Profiles \(appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

/// Rows in a subtle grouped container, macOS-settings style.
struct GroupBoxList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 2) { content }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }
}

/// The panel's ProfileRow scaled up for the window: bigger avatar, labeled
/// always-visible context chips, rename/delete hover-revealed + context menu.
struct WindowProfileRow: View {
    let name: String
    let subtitle: String?
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
        HStack(spacing: 10) {
            Avatar(name: name, active: desktopActive, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if hovering && !disabled {
                if let onRename {
                    IconButton(systemName: "pencil", help: "Rename", action: onRename)
                }
                if let onDelete {
                    IconButton(systemName: deleteIcon, help: deleteHelp, action: onDelete)
                }
            }
            if let onDesktop {
                ContextChip(label: "Desktop", systemName: "macwindow",
                            active: desktopActive, present: hasDesktop, disabled: disabled,
                            help: desktopActive ? "Active in Claude Desktop"
                                : hasDesktop ? "Use in Claude Desktop"
                                : "Use in Claude Desktop (logs in once)",
                            action: onDesktop)
            }
            if let onCLI {
                ContextChip(label: "CLI", systemName: "terminal",
                            active: cliActive, present: hasCLI, disabled: false,
                            help: cliActive ? "Active for claude in the terminal"
                                : hasCLI ? "Use for claude in the terminal — instant"
                                : "Use for claude in the terminal (logs in once)",
                            action: onCLI)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(desktopActive ? accent.opacity(0.12)
                      : hovering ? Color.primary.opacity(0.05)
                      : .clear)
        )
        .contentShape(Rectangle())
        .contextMenu { rowMenu }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var rowMenu: some View {
        if let onRename { Button("Rename…", action: onRename) }
        if let onDelete { Button(deleteIcon == "trash" ? "Delete (logout)…" : "Hide", action: onDelete) }
    }
}

/// Grid variant: avatar on top, compact context icons below. Rename/delete
/// live in the context menu — cards are too small for hover buttons.
struct WindowProfileCard: View {
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
    var deleteLabel = "Delete (logout)…"
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Avatar(name: name, active: desktopActive, size: 36)
            Text(name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                if let onDesktop {
                    ContextIcon(systemName: "macwindow",
                                active: desktopActive, present: hasDesktop, disabled: disabled,
                                help: desktopActive ? "Active in Claude Desktop"
                                    : hasDesktop ? "Use in Claude Desktop"
                                    : "Use in Claude Desktop (logs in once)",
                                action: onDesktop)
                }
                if let onCLI {
                    ContextIcon(systemName: "terminal",
                                active: cliActive, present: hasCLI, disabled: false,
                                help: cliActive ? "Active for claude in the terminal"
                                    : hasCLI ? "Use for claude in the terminal — instant"
                                    : "Use for claude in the terminal (logs in once)",
                                action: onCLI)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(desktopActive ? accent.opacity(0.12)
                      : hovering ? Color.primary.opacity(0.05)
                      : Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(desktopActive ? accent.opacity(0.4) : Color.primary.opacity(0.06))
        )
        .contentShape(Rectangle())
        .contextMenu {
            if let onRename { Button("Rename…", action: onRename) }
            if let onDelete { Button(deleteLabel, action: onDelete) }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(name)
    }
}

/// Labeled variant of the panel's ContextIcon: capsule chip, always visible.
struct ContextChip: View {
    let label: String
    let systemName: String
    let active: Bool
    let present: Bool
    let disabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? AnyShapeStyle(accent)
                : hovering ? AnyShapeStyle(Color.primary)
                : AnyShapeStyle(Color.secondary.opacity(present ? 0.9 : 0.5)))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(active ? accent.opacity(0.15)
                : hovering ? Color.primary.opacity(0.08)
                : Color.primary.opacity(0.04)))
        }
        .buttonStyle(PressableStyle())
        .disabled(active || disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

// MARK: - About & Updates

/// Manual-only update check: one GitHub API request when the user clicks the
/// button, never in the background — the app's "no internet access" promise
/// stays true for everything it does on its own.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = Status.idle

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Claude Profiles")
                .font(.system(size: 15, weight: .semibold))
            Text("Version \(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            updateArea
                .frame(height: 44)

            Link(destination: githubURL) {
                Label("ajipurn/claude-profiles", systemImage: "link")
                    .font(.system(size: 11))
            }
            Text("Not affiliated with Anthropic.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 300)
    }

    @ViewBuilder private var updateArea: some View {
        switch status {
        case .idle:
            Button("Check for Updates…") { check() }
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .available(let tag):
            VStack(spacing: 4) {
                Text("\(tag) is available")
                    .font(.system(size: 11, weight: .medium))
                Link("Open Releases", destination: githubURL.appendingPathComponent("releases/latest"))
                    .font(.system(size: 11))
            }
        case .failed(let why):
            VStack(spacing: 4) {
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Try Again") { check() }
                    .controlSize(.small)
            }
        }
    }

    private func check() {
        status = .checking
        Task {
            do {
                let api = URL(string: "https://api.github.com/repos/ajipurn/claude-profiles/releases/latest")!
                let (data, response) = try await URLSession.shared.data(from: api)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    status = .failed("No release found")
                    return
                }
                status = AppVersion.isNewer(tag, than: appVersion) ? .available(tag) : .upToDate
            } catch {
                status = .failed("Couldn't reach GitHub")
            }
        }
    }
}
