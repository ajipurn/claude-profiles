<p align="center">
  <img src="docs/icon.png" width="128" alt="Claude Profiles icon">
</p>

<h1 align="center">Claude Profiles</h1>

<p align="center">
  Switch between Claude Desktop accounts in seconds — log in once per account, never again.
</p>

---

Claude Desktop only remembers **one** login at a time. Switching accounts normally means logging out, logging back in, and losing your sidebar history every single time.

**Claude Profiles** fixes that. It lives in your menu bar and keeps a separate, fully-logged-in copy of Claude for every account you use. Switching takes about 5 seconds: Claude quits, the app swaps profiles, Claude reopens — already logged in.

## Features

- 🔁 **Instant account switching** — one click in the menu bar (or right-click for the quick menu), ~5 seconds, no login screen
- 📊 **Usage limits per account** — every profile shows its official session & weekly usage (as of that account's last use), read from Claude's own local cache
- ◐ **Live menu bar gauge** — what's left of the active account's 5-hour window, colored green/yellow/red, updated the moment Claude refreshes its own numbers; in the red it adds a countdown to the reset
- 🔔 **Low-limit alerts** — under 10% left, a notification suggests your freshest account; clicking it switches immediately
- 🗂 **Shared session history** *(optional)* — all your accounts see one combined sidebar, so nothing "disappears" when you switch
- ⌨️ **Claude Code (CLI) too** *(optional)* — one list for everything: each profile can be used for Desktop, for `claude` in the terminal, or both
- ⚡ **Hotkeys & scripting** — ⌘⌥1…9 switches to the Nth profile from anywhere; `claudeprofiles://switch/<name>` does it from Raycast, Alfred, or a shell
- ✏️ **Rename & delete profiles** — in the window view; deleting a profile = logging that account out
- 🚀 **Launch at login**, zero setup after the first run
- 🔒 **Private by design** — no analytics, and it never reads your passwords, cookies, or tokens. It only moves folders around on your Mac and reads Claude's own local files. Its only self-initiated network request is the optional weekly update check.

## Requirements

- macOS 13 (Ventura) or newer
- [Claude Desktop](https://claude.ai/download) installed in `/Applications`

## Install

1. Download `ClaudeProfiles.dmg` from the [latest release](../../releases/latest).
2. Open it and drag **Claude Profiles** onto the **Applications** shortcut next to it.
3. Open the app once — macOS will show a warning. **This is expected**, see below.

### "Apple could not verify this app is free of malware…"

This build isn't notarized by Apple yet (that requires a paid Apple Developer account — it's on the roadmap). The app is open source, makes no network connections beyond an optional weekly update check, and you can read every line it runs — but macOS can't know that, so it warns you **once**. How to get past it:

**macOS 15 (Sequoia) and newer:**

1. Double-click the app → the warning appears → click **Done** (not "Move to Trash").
2. Open **System Settings → Privacy & Security**, scroll down to
   *"Claude Profiles.app was blocked to protect your Mac"* → click **Open Anyway**.
3. Confirm with your password or Touch ID. macOS never asks again.

**macOS 13–14 (Ventura / Sonoma):**

1. **Right-click** (or Control-click) the app → **Open** → **Open**. Once, done.

**Prefer the terminal?** This removes the quarantine mark directly:

```sh
xattr -d com.apple.quarantine "/Applications/Claude Profiles.app"
```

**Don't want to trust a downloaded build at all?** Build it yourself from source in ~2 minutes — see [For developers](#for-developers). Apps you build locally never get the warning.

After that, a <img src="docs/icon.png" width="14"> person icon appears in your menu bar — you're set.

## Getting started

1. **Click the menu bar icon → "Set Up Profiles…"**
   Your current Claude login is saved as your first profile (call it anything — "personal", "work", your email…). Nothing moves and Claude keeps running — the folder just gains a name.
2. **Click "New Profile"** to add another account.
   This only adds it to the list — your current session keeps running, nothing restarts.
3. **Switch** by clicking any profile in the list. The first switch to a new profile shows
   Claude's login screen — log in with the other account. That's the **only** time you'll
   ever log into it. After that, switching is instant and login-free.
4. *(Shared history only)* Claude loads its sidebar at startup, so a freshly logged-in
   account needs one reload to see the combined history. The app detects the login and
   offers to restart Claude for you — one click, done.

### Sharing your session history (optional, recommended)

By default each account has its own sidebar history. Click **"Share Session History…"** once and every profile will show one combined list — switching accounts never hides your sessions again.

A timestamped backup of your history is saved in your home folder first (`claude-session-backup-…`), so this is safe to try.

### Claude Code (CLI) profiles (optional)

If you also use `claude` in the terminal, the same profiles can switch that account too:

1. Click **"Set Up CLI Profiles…"** in the panel.
2. Add the one line it shows you to the end of `~/.zshrc`, then open a new terminal.

Every profile row now shows two small icons — a **window** (Claude Desktop) and a **terminal** (`claude` CLI). Orange means *active there*, grey means *set up there*, faint means *not used there yet*. Click an icon to use that profile in that context; the first time, it asks you to log in once (Desktop and CLI logins are separate systems, so this can't be skipped — but it's once, ever).

CLI switching is **instant** — nothing quits — and applies to `claude` commands you start *from then on*; terminals already running keep their account, so switching can never interrupt work in progress. It also works without leaving the terminal — handy for scripts, Raycast, or Alfred:

```sh
claude-profile work      # switch (new claude runs only)
claude-profile           # show the active profile
claude-profile list      # list profiles
claude-profile default   # back to plain ~/.claude
```

The **Default** row is your original `~/.claude` account, untouched — with all the settings and plugins you've built up there, which new CLI profiles don't inherit. Don't use it? Hover it and click the eye to hide the row (nothing is deleted; bring it back via the **?** button). Your own `CLAUDE_CONFIG_DIR` or aliases always take priority over the selection.

## FAQ

**Why does macOS warn me the app might be malware?**
Because this build isn't notarized (Apple's paid code-review stamp) — not because anything was detected. macOS shows that exact dialog for *every* un-notarized app. See [the install section](#apple-could-not-verify-this-app-is-free-of-malware) for the one-time fix, or build from source to skip it entirely.

**Is this safe? Where does my data go?**
Everything stays on your Mac. The app is open source and never touches passwords, cookies, or tokens — it only moves and links folders, and reads a few of Claude's own local files (its config, and its cache for the usage display). Its one self-initiated network request is an optional weekly update check against GitHub's public releases feed (nothing about you or your profiles is sent; turn it off in Settings → General). Your profiles live in `~/Library/Application Support/Claude-Profiles/`, as plain folders you can open in Finder.

**Where do the usage numbers come from? Are they live?**
From Claude itself: Claude Desktop regularly asks claude.ai how much of your limit is used, and keeps the answer in its local cache. The app reads that cache — per profile, fully offline. So the numbers are exactly what that account last saw: near-live for the profile you're using now, older for profiles you haven't opened in a while (the tooltip shows when they were from). Windows whose reset time has passed are dropped rather than shown stale.

**Why does logging in still work after switching?**
Claude's login encryption key is stored per **app** in your Mac's Keychain, not per account. Every profile folder stays readable by the same Claude app.

**How do CLI profiles work? Why does renaming warn about the CLI login?**
Claude Code natively supports separate config folders (`CLAUDE_CONFIG_DIR`), each with its own isolated login. The app just maintains those folders and a tiny `claude` launcher script that picks the selected one — no symlinks, no restarts. Claude Code ties each folder's login to its *path*, so renaming a profile logs its CLI side out (the Desktop login is kept; you log the CLI in once again). Deleting a profile removes its data; a CLI login token stays in your Keychain until you remove it yourself (Keychain Access), because this app never touches Keychain items.

**What does deleting a profile do?**
It logs that account out by removing its saved login. You'd have to log in again next time. With shared history enabled, your session list survives.

**How do I uninstall?**
Just trash Claude Profiles.app. Your active account already lives exactly where Claude expects it (`~/Library/Application Support/Claude` is a normal folder), so Claude keeps working untouched. Your other profiles stay in `~/Library/Application Support/Claude-Profiles` — keep them, or delete that folder to log those accounts out for good.

**Something looks broken.**
The panel will warn you and switching to any profile fixes it. Every switch is journaled: if anything (even a crash mid-switch) interrupts it, the app finishes or rolls it back at the next launch. Worst case: your data is always intact inside the Claude folder, `Claude-Profiles/`, or the backups — nothing the app does can silently destroy it. It refuses, by design, to ever delete or overwrite a real folder.

---

## For developers

Native Swift/SwiftUI, no package dependencies (one vendored C library: zstd's decompress side, in `Sources/CZstd/`, BSD-licensed — Claude's HTTP cache stores bodies zstd-compressed and macOS has no system decoder). `~/Library/Application Support/Claude` is a **real directory** holding the active profile; inactive profiles are real directories in `Claude-Profiles/`, and a `_active` file records which name the live directory belongs to. Switching = quit Claude → journal the intent → two same-volume `rename(2)` calls (Claude out to the old profile's slot, the new profile in) → relaunch. A crash at any point leaves a state the journal finishes or rolls back at next launch.

Why not symlinks (the app's original design)? Claude's Cowork feature mounts session directories into its VM with `openat2(RESOLVE_NO_SYMLINKS)`, which refuses to traverse *any* symlink — one link anywhere in the active path and every Cowork session fails to start. So the invariant is: **the active profile's paths contain no symlink, ever**. Inactive profiles may be reached through links (they're not mounted); all of those links use relative targets so they still resolve inside the VM's shifted mount root.

Shared history keeps the merged session trees (`claude-code-sessions`, `local-agent-mode-sessions`) *inside the live Claude directory*; inactive profiles symlink theirs to it, and the master `<account>/<org>` dir moves to the active account's slot on every switch (everyone else's org dir is a link to it). The merge is idempotent and re-runs on every switch, so accounts that log in later join automatically.

The usage display parses the newest cached `GET /api/organizations/<org>/usage` response out of each profile's `Cache/Cache_Data` (Chromium simple-cache entries, zstd bodies). All of that is Anthropic/Chromium internals, so every parse step fails soft — worst case the usage line simply doesn't show.

CLI profiles are plain `CLAUDE_CONFIG_DIR` dirs under `Claude-Profiles/_cli/profiles/`. A `/bin/sh` shim at `_cli/bin/claude` (prepended to PATH) reads the selected name from `_cli/active` at every launch and `exec`s the next `claude` on PATH — an already-exported `CLAUDE_CONFIG_DIR` wins, and macOS Keychain isolation per config dir is Claude Code's own behavior. `_cli/bin/claude-profile` is a second tiny script that rewrites `_cli/active` from the terminal; both are rewritten at every app launch, so they stay current after updates.

```sh
swift run     # run from source (menu bar app, no bundle niceties)
swift test    # unit tests — needs full Xcode (XCTest isn't in the CLI tools)
```

### App bundle

```sh
sh scripts/make-app.sh        # → dist/Claude Profiles.app (works with just Command Line Tools)
```

This is the same script CI uses for releases: SwiftPM build plus a hand-assembled,
ad-hoc signed bundle — no Xcode needed. (`xcodegen` still generates a project for
editing in Xcode, but its single-target layout can't build the app.)

App Sandbox is off on purpose — the app manages another app's data directory and lifecycle, which the sandbox forbids. Direct distribution only (no Mac App Store).

### Notarization

```sh
codesign --force --options runtime --deep --sign "Developer ID Application: NAME (TEAM)" ClaudeProfiles.app
ditto -c -k --keepParent ClaudeProfiles.app ClaudeProfiles.zip
xcrun notarytool submit ClaudeProfiles.zip --keychain-profile AC_PROFILE --wait
xcrun stapler staple ClaudeProfiles.app
```

### Layout

```
Sources/ClaudeProfilesCore/   ProfileManager — all filesystem logic, no UI imports, unit-tested
Sources/ClaudeProfiles/       SwiftUI menu bar panel, Claude.app lifecycle, notifications
Tests/                        ProfileManager tests against a temporary fake home directory
project.yml                   xcodegen config for the .app bundle
```

---

*Not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic, PBC.*
