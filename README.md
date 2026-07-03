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

- 🔁 **Instant account switching** — one click in the menu bar, ~5 seconds, no login screen
- 🗂 **Shared session history** *(optional)* — all your accounts see one combined sidebar, so nothing "disappears" when you switch
- ✏️ **Rename & delete profiles** — hover a profile in the panel; deleting a profile = logging that account out
- 🚀 **Launch at login**, zero setup after the first run
- 🔒 **Private by design** — no internet access, no analytics, and it never reads your passwords, cookies, or tokens. It only moves folders around on your Mac.

## Requirements

- macOS 13 (Ventura) or newer
- [Claude Desktop](https://claude.ai/download) installed in `/Applications`

## Install

1. Download `ClaudeProfiles.zip` from the [latest release](../../releases/latest).
2. Unzip it and drag **Claude Profiles.app** into your **Applications** folder.
3. Open it once — macOS will show a warning. **This is expected**, see below.

### "Apple could not verify this app is free of malware…"

This build isn't notarized by Apple yet (that requires a paid Apple Developer account — it's on the roadmap). The app is open source, makes no network connections, and you can read every line it runs — but macOS can't know that, so it warns you **once**. How to get past it:

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
   Your current Claude login is saved as your first profile (call it anything — "personal", "work", your email…). Claude restarts, still logged in. Nothing is lost.
2. **Click "New Profile"** to add another account.
   Claude opens with a login screen — log in with the other account. That's the **only** time you'll ever log into it.
3. **Switch** by clicking any profile in the list. Done.

### Sharing your session history (optional, recommended)

By default each account has its own sidebar history. Click **"Share Session History…"** once and every profile will show one combined list — switching accounts never hides your sessions again.

A timestamped backup of your history is saved in your home folder first (`claude-session-backup-…`), so this is safe to try.

## FAQ

**Why does macOS warn me the app might be malware?**
Because this build isn't notarized (Apple's paid code-review stamp) — not because anything was detected. macOS shows that exact dialog for *every* un-notarized app. See [the install section](#apple-could-not-verify-this-app-is-free-of-malware) for the one-time fix, or build from source to skip it entirely.

**Is this safe? Where does my data go?**
Everything stays on your Mac. The app is open source, makes zero network requests, and never touches passwords, cookies, or tokens — it only moves and links folders. Your profiles live in `~/Library/Application Support/Claude-Profiles/`, as plain folders you can open in Finder.

**Why does logging in still work after switching?**
Claude's login encryption key is stored per **app** in your Mac's Keychain, not per account. Every profile folder stays readable by the same Claude app.

**What does deleting a profile do?**
It logs that account out by removing its saved login. You'd have to log in again next time. With shared history enabled, your session list survives.

**How do I uninstall?**
Quit the app, then move your active profile back where Claude expects it:

```
1. Open Finder → Go → Go to Folder… → ~/Library/Application Support
2. Delete the "Claude" shortcut (it's just a link, not your data)
3. Open Claude-Profiles, drag your main profile folder out, rename it to "Claude"
4. Trash Claude Profiles.app
```

**Something looks broken.**
The panel will warn you and switching to any profile fixes the link. Worst case: your data is always intact inside `Claude-Profiles/` and the backups — nothing the app does can silently destroy it. It refuses, by design, to ever delete or overwrite a real folder.

---

## For developers

Native Swift/SwiftUI, zero dependencies. `~/Library/Application Support/Claude` becomes a symlink into `Claude-Profiles/<name>/`; switching = quit Claude → repoint symlink → relaunch. Shared history merges the per-account session trees (`claude-code-sessions`, `local-agent-mode-sessions`) into `_shared-sessions/` and symlinks every `<account>/<org>` dir to the one with the most files. The merge is idempotent and re-runs on every switch, so accounts that log in later join automatically.

```sh
swift run     # run from source (menu bar app, no bundle niceties)
swift test    # unit tests — needs full Xcode (XCTest isn't in the CLI tools)
```

### App bundle

```sh
brew install xcodegen
xcodegen                      # generates ClaudeProfiles.xcodeproj (LSUIElement, hardened runtime)
xcodebuild -project ClaudeProfiles.xcodeproj -scheme ClaudeProfiles -configuration Release build
```

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
