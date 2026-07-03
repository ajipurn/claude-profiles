# Claude Profiles

Native macOS menu bar app for instant Claude Desktop account switching. No Dock icon, no dependencies, no network access.

## How it works

Claude Desktop keeps all login state (encrypted cookies, tokens, local storage) in
`~/Library/Application Support/Claude`. This app:

1. Moves that directory to `~/Library/Application Support/Claude-Profiles/<name>/` (one directory per account).
2. Replaces `~/Library/Application Support/Claude` with a **symlink** to the active profile.
3. Switching = gracefully quit Claude → repoint the symlink → relaunch (~3–5 s). You log in once per profile, ever.

This works because Electron's cookie-encryption key lives in the macOS Keychain **per app**, not per login — every profile directory stays decryptable by the same Claude.app.

The app never reads, parses, or copies cookies, tokens, or Keychain items. Directories are moved and symlinked as opaque blobs.

### Shared session history (optional)

Claude's sidebar reads session indexes from
`<profile>/claude-code-sessions/<account-uuid>/<org-uuid>/` (and `local-agent-mode-sessions/`),
keyed by the logged-in account. "Share session history" merges every profile's trees into
`Claude-Profiles/_shared-sessions/` and symlinks them back, then links every `<account>/<org>`
directory to the one with the most files — so all accounts see one combined list.
A timestamped backup (`~/claude-session-backup-<yyyyMMdd-HHmmss>/`) is created first.
The operation is idempotent, and new profiles are linked to the shared trees automatically.

## Safety rails

- Nothing that exists and is **not a symlink** is ever deleted or overwritten. If
  `~/Library/Application Support/Claude` is a real directory, the only allowed operation is first-run migration (a `mv`, no copy/delete).
- Merges copy before deleting; backups happen before any merge. A crash mid-switch never loses data.
- If Claude won't quit (even after force-terminate), the switch is aborted and the symlink left untouched.

## Build & run

### Development (SwiftPM)

```sh
swift run          # runs the menu bar app from the terminal
swift test         # unit tests (ProfileManager against a fake home dir)
```

`swift test` needs a full Xcode install (XCTest is not in the Command Line Tools).

Note: when run via `swift run` there is no `.app` bundle, so user notifications fall back to
log lines and "Launch at login" is unavailable. Use the app bundle for the real experience.

### App bundle (xcodegen)

```sh
brew install xcodegen
xcodegen                       # generates ClaudeProfiles.xcodeproj from project.yml
xcodebuild -project ClaudeProfiles.xcodeproj -scheme ClaudeProfiles -configuration Release build
```

The generated `Info.plist` sets `LSUIElement` (menu bar only). Hardened Runtime is on,
App Sandbox is off — the app writes to `~/Library/Application Support` and manages another
app's lifecycle, which the sandbox forbids. **Direct distribution only; cannot ship on the Mac App Store.**

### Notarization (direct distribution)

```sh
# 1. Sign with a Developer ID Application certificate
codesign --force --options runtime --deep \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" ClaudeProfiles.app

# 2. Submit to Apple
ditto -c -k --keepParent ClaudeProfiles.app ClaudeProfiles.zip
xcrun notarytool submit ClaudeProfiles.zip --keychain-profile "AC_PROFILE" --wait

# 3. Staple the ticket
xcrun stapler staple ClaudeProfiles.app
```

(`AC_PROFILE` = credentials stored via `xcrun notarytool store-credentials`.)

## Uninstall / manual recovery

Everything is plain directories and symlinks; recovery never needs the app:

```sh
APP_SUPPORT=~/Library/Application\ Support
rm "$APP_SUPPORT/Claude"                              # remove the symlink (only if it IS a symlink)
mv "$APP_SUPPORT/Claude-Profiles/main" "$APP_SUPPORT/Claude"   # restore a profile as the real dir
```

Session-history backups live at `~/claude-session-backup-<timestamp>/`.

## Layout

```
Sources/ClaudeProfilesCore/   ProfileManager — all filesystem logic, no UI imports, unit-tested
Sources/ClaudeProfiles/       SwiftUI MenuBarExtra, Claude.app lifecycle, notifications
Tests/                        ProfileManager tests against a temporary fake home directory
project.yml                   xcodegen config for the .app bundle
```
