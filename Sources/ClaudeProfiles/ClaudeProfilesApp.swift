import SwiftUI
import AppKit
import Combine
import ServiceManagement
import ClaudeProfilesCore

let accent = Color(red: 0.85, green: 0.47, blue: 0.34) // matches the app icon

@main
struct ClaudeProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // All real UI is AppKit-owned (status item, popover, main window):
        // MenuBarExtra cannot see right-clicks and its window has no arrow.
        Settings { EmptyView() }
    }
}

// MARK: - App delegate

/// Owns the status item, the arrow popover (left-click), the quick-switch
/// menu (right-click) and the main window. NSStatusItem + NSPopover instead
/// of MenuBarExtra so both mouse buttons work and the panel gets the native
/// popover chrome.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 20, height: 20)
        return image // full-color; the dark outline reads fine in both menu bar modes
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        state.openWindowHandler = { [weak self] in self?.showMainWindow() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "dev.local.ClaudeProfiles.status"
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusImage()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: PanelView.width, height: PanelView.height)
        popover.appearance = NSAppearance(named: .darkAqua) // ClaudeBar-style dark theme
        popover.contentViewController = NSHostingController(rootView: PanelView(state: state))

        // The status image is derived state; redraw after every model change
        // (async so the @Published values have actually been written).
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusImage() }
            }
            .store(in: &cancellables)
        // Composite images bake in the text color, so menu bar theme flips
        // need a redraw too.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.updateStatusImage() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: Status item

    private func updateStatusImage() {
        guard let button = statusItem?.button else { return }
        if state.isSwitching {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                   accessibilityDescription: "Switching")
        } else if state.mode == .ready, let active = state.activeProfile,
                  let remaining = state.usage[active]?.fiveHourRemaining {
            button.image = MenuBarLevel.composite(remaining: remaining)
        } else {
            let initials = state.mode == .ready ? state.activeProfile.map(Avatar.initials) : nil
            button.image = MenuBarLevel.plain(icon: Self.menuBarIcon, initials: initials)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Right-click quick menu

    private func showContextMenu() {
        let menu = NSMenu()
        if state.mode == .ready {
            for (index, name) in state.allProfiles.enumerated() {
                var title = "\(index + 1). \(name)"
                if let remaining = state.usage[name]?.fiveHourRemaining {
                    title += " — \(remaining)%"
                }
                let item = NSMenuItem(title: title,
                                      action: #selector(menuSwitchProfile(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = name == state.activeProfile ? .on : .off
                if name == state.activeProfile || state.isSwitching || !state.claudeAppFound {
                    item.action = nil // no action = disabled row, checkmark still shows
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("Open Claude Profiles", #selector(menuOpenWindow), key: "o"))
        menu.addItem(menuItem("Refresh Usage", #selector(menuRefreshUsage), key: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Profiles",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        // Momentary menu: attach, click, detach — so the next left-click still
        // opens the popover instead of this menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuSwitchProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        state.switchTo(name)
    }

    @objc private func menuOpenWindow() { showMainWindow() }
    @objc private func menuRefreshUsage() { state.refreshUsage() }

    // MARK: Main window

    private func showMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            // The app stays a menu bar accessory; the Dock icon exists only
            // while this window is open (the view's own appear handlers flip
            // the activation policy, same as the old Window scene did).
            let host = NSHostingController(rootView:
                WindowView(state: state)
                    .onAppear {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .onDisappear { NSApp.setActivationPolicy(.accessory) }
            )
            let window = NSWindow(contentViewController: host)
            window.appearance = NSAppearance(named: .darkAqua) // match the panel's dark theme
            window.title = "Claude Profiles"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 660))
            window.contentMinSize = NSSize(width: 460, height: 440)
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Menu bar images

/// Menu bar readout, drawn with AppKit into a single full-color NSImage
/// (ClaudeBar-style): "◐ 51%" — the dot and the remaining share of the
/// active account's 5-hour window, both tinted green/yellow/red like the
/// window's meters. One image because macOS flattens any other status-item
/// content to a monochrome template, and sibling views next to an NSImage
/// proved unreliable.
enum MenuBarLevel {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func composite(remaining: Int) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "text-\(remaining)-\(dark)"
        if let hit = cache[key] { return hit }

        let color: NSColor = remaining > 40 ? .systemGreen
            : remaining > 10 ? .systemYellow : .systemRed
        // Same face as ClaudeBar's readout.
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        let attr = NSAttributedString(string: "\(remaining)%",
                                      attributes: [.font: font, .foregroundColor: color])

        let textSize = attr.size()
        let padding: CGFloat = 6
        let dotSide: CGFloat = 10
        let gap: CGFloat = 4
        let size = NSSize(width: padding + dotSide + gap + ceil(textSize.width) + padding,
                          height: NSStatusBar.system.thickness)

        let image = NSImage(size: size, flipped: false) { _ in
            // Solid black pill behind the readout — the colored text alone
            // washes out on bright wallpapers under the translucent menu bar.
            let pillHeight: CGFloat = 20
            let pill = NSRect(x: 0, y: (size.height - pillHeight) / 2,
                              width: size.width, height: pillHeight)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()

            // The dot is a live gauge, not a glyph: a ring whose pie fill is
            // the remaining share — full disc at 100%, a sliver near empty.
            let dotRect = NSRect(x: padding, y: (size.height - dotSide) / 2,
                                 width: dotSide, height: dotSide)
            color.set()
            if remaining >= 100 {
                NSBezierPath(ovalIn: dotRect).fill()
            } else if remaining > 0 {
                let wedge = NSBezierPath()
                let center = NSPoint(x: dotRect.midX, y: dotRect.midY)
                wedge.move(to: center)
                wedge.appendArc(withCenter: center, radius: dotSide / 2,
                                startAngle: 90,
                                endAngle: 90 - 360 * CGFloat(remaining) / 100,
                                clockwise: true)
                wedge.close()
                wedge.fill()
            }
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()

            attr.draw(at: NSPoint(x: padding + dotSide + gap,
                                  y: (size.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }

    /// The no-usage fallback (icon plus the active profile's initials),
    /// pre-rendered for the same reason as `composite`.
    @MainActor static func plain(icon: NSImage?, initials: String?) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let text = initials ?? (icon == nil ? "CP" : nil) // `swift run` has no bundle resources
        let key = "plain-\(text ?? "")-\(dark)-\(icon != nil)"
        if let hit = cache[key] { return hit }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: dark ? NSColor.white : NSColor.black.withAlphaComponent(0.85),
        ]
        let textSize = (text as NSString?)?.size(withAttributes: attrs) ?? .zero
        let iconSide: CGFloat = icon == nil ? 0 : 20
        let gap: CGFloat = (icon != nil && text != nil) ? 3 : 0
        let size = NSSize(width: max(iconSide + gap + ceil(textSize.width), 14), height: 20)

        let image = NSImage(size: size, flipped: false) { _ in
            icon?.draw(in: NSRect(x: 0, y: 0, width: iconSide, height: iconSide))
            (text as NSString?)?.draw(
                at: NSPoint(x: iconSide + gap, y: (size.height - textSize.height) / 2),
                withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

// MARK: - Panel

/// The popover: header (active profile + usage summary + refresh), pill tabs,
/// scrolling content, pinned footer — fixed size so long profile lists scroll
/// instead of growing past the screen.
struct PanelView: View {
    @ObservedObject var state: AppState
    @State private var tab: PanelTab = .profiles
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    static let width: CGFloat = 340
    static let height: CGFloat = 480

    enum PanelTab: String, CaseIterable, Identifiable {
        case profiles = "Profiles"
        case usage = "Usage"
        case more = "More"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            if state.mode == .needsSetup {
                if !state.claudeAppFound {
                    Banner(icon: "exclamationmark.triangle.fill",
                           text: "Claude.app not found in /Applications or ~/Applications")
                        .padding(12)
                }
                Spacer()
                SetupView(state: state)
                Spacer()
            } else {
                tabBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .profiles: profilesTab
                        case .usage: UsageTab(state: state)
                        case .more: moreTab
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: Self.width, height: Self.height)
        .onAppear { state.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if state.mode == .ready, let active = state.activeProfile {
                Avatar(name: active, active: true, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(active)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Profiles").font(.headline)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            IconButton(systemName: "macwindow.on.rectangle", help: "Open as window") {
                state.openWindowHandler?()
            }
            IconButton(systemName: state.usageScanRunning ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                       help: "Re-read usage from Claude's cache") {
                state.refreshUsage()
            }
            .disabled(state.usageScanRunning)
        }
    }

    private var subtitle: String {
        if state.isSwitching { return "Switching…" }
        guard state.mode == .ready else { return "One folder per account" }
        guard let active = state.activeProfile else { return "No active profile" }
        guard let usage = state.usage[active], usage.hasLiveWindows else { return "No usage data yet" }
        return usage.levels.map { "\($0.label) \($0.remaining)% left" }.joined(separator: " · ")
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tab == candidate ? accent.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(tab == candidate ? accent : Color.secondary)
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
        }
    }

    // MARK: Profiles tab

    // Rename/delete/hide live in the window app only — hover buttons made
    // these compact rows a mess. The panel is for switching.
    private var profilesTab: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !state.claudeAppFound {
                Banner(icon: "exclamationmark.triangle.fill",
                       text: "Claude.app not found in /Applications or ~/Applications")
            }
            if state.brokenLink {
                Banner(icon: "link.badge.plus",
                       text: "Active profile is missing — pick a profile to fix it")
            }
            if state.cliSetUp && !state.cliDefaultHidden {
                // The CLI's default account: plain ~/.claude, no Desktop side.
                ProfileRow(name: "Default",
                           hasDesktop: false, hasCLI: true,
                           desktopActive: false,
                           cliActive: state.activeCLIProfile == nil,
                           disabled: false,
                           onDesktop: nil,
                           onCLI: { state.switchCLI(nil) })
            }
            ForEach(state.allProfiles, id: \.self) { name in
                ProfileRow(
                    name: name,
                    usage: state.usage[name],
                    hasDesktop: state.profiles.contains(name),
                    hasCLI: state.cliCreated.contains(name),
                    desktopActive: name == state.activeProfile,
                    cliActive: name == state.activeCLIProfile,
                    disabled: !state.claudeAppFound || state.isSwitching,
                    onDesktop: { state.switchTo(name) },
                    onCLI: state.cliSetUp ? { state.switchCLI(name) } : nil
                )
            }
            ActionRow(icon: "plus.circle.fill", title: "New Profile", tint: accent,
                      disabled: !state.claudeAppFound || state.isSwitching) {
                state.newProfile()
            }
        }
    }

    // MARK: More tab

    private var moreTab: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !state.cliSetUp {
                ActionRow(icon: "terminal", title: "Set Up CLI Profiles…") {
                    state.setUpCLIProfiles()
                }
            } else {
                ActionRow(icon: "questionmark.circle", title: "CLI Terminal Setup…") {
                    state.showCLIPathHelp()
                }
            }
            if !state.sharedHistoryEnabled {
                ActionRow(icon: "clock.arrow.2.circlepath", title: "Share Session History…",
                          disabled: !state.claudeAppFound || state.isSwitching) {
                    state.enableSharedHistory()
                }
            }
            ActionRow(icon: "folder", title: "Reveal Profiles in Finder") {
                state.revealProfilesFolder()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("[Claude Profiles] Launch at login failed: %@", error.localizedDescription)
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            if let scanned = state.lastUsageScan {
                Text(scanned.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Last usage scan")
            }
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Usage tab

/// The active profile's cached limits as a hero readout, then every profile's
/// meters — same battery-style remaining semantics as the window app.
private struct UsageTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            activeSection
            Divider()
            allSection
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Active profile")
            if let active = state.activeProfile {
                if let usage = state.usage[active], usage.hasLiveWindows {
                    let remaining = usage.fiveHourRemaining ?? 100
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(remaining)%")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(ProfileUsage.remainingColor(remaining))
                        Text("of the 5-hour window left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack(spacing: 16) {
                        if let five = usage.fiveHour {
                            PanelStat(label: "5h resets", value: Self.resetText(five))
                        }
                        if let week = usage.sevenDay {
                            PanelStat(label: "Week left", value: "\(week.remainingPercent)%",
                                      color: ProfileUsage.remainingColor(week.remainingPercent))
                            PanelStat(label: "Week resets", value: Self.resetText(week))
                        }
                    }
                    .padding(.top, 2)
                    Text("From Claude's last check, \(Self.relative(usage.asOf))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                } else {
                    Text("No usage data yet — open Claude with this profile once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No active profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("All profiles")
            ForEach(state.allProfiles, id: \.self) { name in
                HStack(spacing: 8) {
                    Avatar(name: name, active: name == state.activeProfile, size: 16)
                    Text(name)
                        .font(.system(size: 12,
                                      weight: name == state.activeProfile ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let usage = state.usage[name], usage.hasLiveWindows {
                        UsageLevels(usage: usage, barWidth: 30)
                    } else {
                        Text("no data")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(name == state.activeProfile ? accent.opacity(0.10)
                              : Color.primary.opacity(0.045))
                )
            }
        }
    }

    /// "14:30" today, "Tue 09:00" otherwise; an expired window already reset.
    static func resetText(_ window: ProfileUsage.Window) -> String {
        guard !window.expired, let date = window.resetsAt else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

/// Small label-over-value column, ClaudeBar-style.
struct PanelStat: View {
    let label: String
    let value: String
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
        }
    }
}

// MARK: - Rows

/// One row per profile, tagged per context: the window icon is Claude Desktop,
/// the terminal icon is claude CLI. At rest a row shows only its *active* tags
/// (accent); hovering reveals both switch buttons — same pattern as the
/// rename/delete actions, so the list stays quiet.
struct ProfileRow: View {
    let name: String
    var usage: ProfileUsage? = nil
    let hasDesktop: Bool
    let hasCLI: Bool
    let desktopActive: Bool
    let cliActive: Bool
    let disabled: Bool
    let onDesktop: (() -> Void)?
    let onCLI: (() -> Void)?
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                        if let usage, usage.hasLiveWindows {
                            UsageLevels(usage: usage, barWidth: 22)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(onDesktop != nil ? (disabled || desktopActive) : cliActive)

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
        .padding(.vertical, 5)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(desktopActive ? accent.opacity(0.13)
                      : hovering ? Color.primary.opacity(0.08)
                      : Color.primary.opacity(0.045))
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

// MARK: - Pieces

struct Avatar: View {
    let name: String
    let active: Bool
    var size: CGFloat = 18

    /// Letters first: "008-purenomo" → "PU", not the "00" every numbered
    /// profile shares. Digits only when the name has no letters at all.
    static func initials(_ name: String) -> String {
        let letters = name.filter(\.isLetter)
        let source = letters.isEmpty ? name.filter(\.isNumber) : letters
        return String((source.isEmpty ? name : source).prefix(2)).uppercased()
    }

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
            Text(Self.initials(name))
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
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

/// Press feedback: subtle scale, fast ease-out. Never from scale(0), never slow.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
