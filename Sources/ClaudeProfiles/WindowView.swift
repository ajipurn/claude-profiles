import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
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
    @State private var page = Page.profiles
    @State private var showAbout = false
    @State private var dragging: String?   // profile being drag-reordered

    enum ViewMode: String { case list, grid }
    enum Page { case profiles, settings }

    var body: some View {
        Group {
            switch state.mode {
            case .needsSetup:
                VStack(alignment: .leading, spacing: 14) {
                    if !state.claudeAppFound {
                        Banner(icon: "exclamationmark.triangle.fill",
                               text: "Claude.app not found in /Applications or ~/Applications")
                    }
                    SetupView(state: state)
                    Spacer(minLength: 0)
                    footer
                }
                .padding(16)
            case .ready:
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        PillPicker(selection: $page, options: [
                            (value: .profiles, title: "Profiles", icon: "person.2"),
                            (value: .settings, title: "Settings", icon: "gearshape"),
                        ])
                        Spacer()
                    }
                    if page == .profiles { profilesPage } else { settingsPage }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity,
               minHeight: 440, idealHeight: 660, maxHeight: .infinity)
        .onAppear { state.refresh() }
        .sheet(isPresented: $showAbout) { AboutView() }
    }

    // MARK: Pages

    private var profilesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !state.claudeAppFound {
                Banner(icon: "exclamationmark.triangle.fill",
                       text: "Claude.app not found in /Applications or ~/Applications")
            }
            if state.brokenLink {
                Banner(icon: "link.badge.plus",
                       text: "Active profile is missing — pick a profile to fix it")
            }
            profilesHeader
            ScrollView {
                if viewMode == .list { profileList } else { profileGrid }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Session History")
                GroupBoxList {
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("Share session history across profiles", isOn: sharedHistoryBinding)
                            .toggleStyle(RaisedToggleStyle())
                        Text("All profiles see one combined sidebar. Turning this off keeps a full copy in every profile; the copies then grow independently.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                }

                SectionLabel("Claude Code (CLI)")
                GroupBoxList {
                    if !state.cliSetUp {
                        ActionRow(icon: "terminal", title: "Set Up CLI Profiles…") {
                            state.setUpCLIProfiles()
                        }
                    } else {
                        Toggle("Show the Default (~/.claude) profile", isOn: defaultRowBinding)
                            .toggleStyle(RaisedToggleStyle())
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                        ActionRow(icon: "questionmark.circle", title: "Terminal Setup Help…") {
                            state.showCLIPathHelp()
                        }
                    }
                }

                SectionLabel("General")
                GroupBoxList {
                    LaunchAtLoginToggle()
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                    ActionRow(icon: "folder", title: "Reveal Profiles in Finder") {
                        state.revealProfilesFolder()
                    }
                }

                SectionLabel("About")
                GroupBoxList {
                    HStack {
                        Text("Version").foregroundStyle(.primary)
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    ActionRow(icon: "info.circle", title: "About & Updates…") {
                        showAbout = true
                    }
                }
            }
        }
    }

    private var sharedHistoryBinding: Binding<Bool> {
        Binding(get: { state.sharedHistoryEnabled },
                set: { $0 ? state.enableSharedHistory() : state.disableSharedHistory() })
    }

    private var defaultRowBinding: Binding<Bool> {
        Binding(get: { !state.cliDefaultHidden },
                set: { state.setDefaultRowHidden(!$0) })
    }

    private var profilesHeader: some View {
        HStack(spacing: 8) {
            SectionLabel("Profiles · \(state.allProfiles.count)")
            Spacer()
            PillPicker(selection: $viewMode, options: [
                (value: .list, title: "", icon: "list.bullet"),
                (value: .grid, title: "", icon: "square.grid.2x2"),
            ])
            Button {
                state.newProfile()
            } label: {
                Label("New Profile", systemImage: "plus")
            }
            .buttonStyle(RaisedPillButtonStyle())
            .disabled(!state.claudeAppFound || state.isSwitching)
        }
    }

    // MARK: Profiles — list

    private var profileList: some View {
        // Drag-reorder via .onDrag + a DropDelegate — macOS List.onMove is too
        // unreliable. The Default row is not draggable and not a drop target.
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
                .opacity(dragging == name ? 0.4 : 1)
                .onDrag {
                    dragging = name
                    return NSItemProvider(object: name as NSString)
                } preview: {
                    DragPreview(name: name)
                }
                .onDrop(of: [.plainText], delegate: ProfileDropDelegate(
                    item: name, order: $state.allProfiles, dragging: $dragging,
                    onDrop: { state.saveProfileOrder() }))
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
                                  deleteLabel: "Hide (nothing is deleted)",
                                  deleteIcon: "eye.slash")
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
                .opacity(dragging == name ? 0.4 : 1)
                .onDrag {
                    dragging = name
                    return NSItemProvider(object: name as NSString)
                } preview: {
                    DragPreview(name: name)
                }
                .onDrop(of: [.plainText], delegate: ProfileDropDelegate(
                    item: name, order: $state.allProfiles, dragging: $dragging,
                    onDrop: { state.saveProfileOrder() }))
            }
        }
        .padding(8)
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

/// Pill segmented control: quiet capsule track, the selected segment is a
/// raised white pill (soft shadow) that slides between options.
struct PillPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, title: String, icon: String?)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        if let icon = option.icon {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .medium))
                        }
                        if !option.title.isEmpty {
                            Text(option.title)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    // Weight stays constant so segment widths never shift while
                    // the pill slides — selection reads from color + the pill.
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, option.title.isEmpty ? 9 : 12)
                    .frame(height: 24)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
    }
}

/// Button as a raised pill, filled with the app accent — the one loud control
/// on the page, so the primary action reads at a glance.
struct RaisedPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            // 30 = PillPicker's outer height (24 segment + 3 track padding × 2),
            // so the button sits flush with pickers on the same row.
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(accent)
                    .shadow(color: accent.opacity(isEnabled ? 0.45 : 0.1), radius: 2, y: 1)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Switch with a raised knob, matching the pill tabs. Track uses the app
/// accent when on — not iOS blue — so the window stays one visual family.
struct RaisedToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? accent : Color.primary.opacity(0.18))
                .frame(width: 36, height: 21)
                .overlay(
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .padding(2.5)
                        .offset(x: configuration.isOn ? 7.5 : -7.5)
                )
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
                }
        }
    }
}

/// Same SMAppService logic as the panel's LaunchAtLoginRow, styled for Settings.
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: $enabled)
            .toggleStyle(RaisedToggleStyle())
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

/// Live reorder for the profile list: as the dragged row passes over another,
/// the array is spliced so rows slide in real time; the drop persists it.
struct ProfileDropDelegate: DropDelegate {
    let item: String
    @Binding var order: [String]
    @Binding var dragging: String?
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onDrop()
        return true
    }
}

/// Drag image for reorder. The default preview snapshots the row, whose
/// background is translucent — over the desktop it reads as a faint shadow.
/// An opaque, tight chip lifts cleanly instead.
struct DragPreview: View {
    let name: String
    var body: some View {
        HStack(spacing: 8) {
            Avatar(name: name, active: false, size: 22)
            Text(name).font(.system(size: 12)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        )
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
            // The clickable region is a Button, not a whole-row .onTapGesture:
            // a tap gesture on the row swallows List's drag, killing reorder.
            // A Button coexists with drag — click switches, drag reorders.
            Button {
                if let onDesktop { onDesktop() } else { onCLI?() }
            } label: {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(disabled || (onDesktop != nil ? desktopActive : cliActive))

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
    var deleteIcon = "trash"
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
        // Clicking the card switches Desktop (CLI for the Default card) —
        // same meaning as list rows and the menu bar panel.
        .onTapGesture {
            guard !disabled else { return }
            if let onDesktop { if !desktopActive { onDesktop() } }
            else if let onCLI, !cliActive { onCLI() }
        }
        // Same hover-reveal as list rows; the context menu stays as a second path.
        .overlay(alignment: .topTrailing) {
            if hovering && !disabled {
                HStack(spacing: 2) {
                    if let onRename {
                        IconButton(systemName: "pencil", help: "Rename", action: onRename)
                    }
                    if let onDelete {
                        IconButton(systemName: deleteIcon, help: deleteLabel, action: onDelete)
                    }
                }
                .padding(3)
            }
        }
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
