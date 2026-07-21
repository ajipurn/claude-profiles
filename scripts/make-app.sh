#!/bin/sh
# Build "Claude Profiles.app" without full Xcode: SwiftPM release build plus a
# hand-assembled bundle, ad-hoc signed. Used by CI for releases and works the
# same on a machine with only Command Line Tools.
#
# Usage: scripts/make-app.sh [version] [build-number]
# Output: dist/Claude Profiles.app
#
# Keep the default version in sync with project.yml (the xcodegen project is
# kept for editing in Xcode; release builds use this script).
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-1.4.1}"
BUILD="${2:-24}"

swift build -c release

APP="dist/Claude Profiles.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>Claude Profiles</string>
	<key>CFBundleExecutable</key><string>ClaudeProfiles</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>dev.local.ClaudeProfiles</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Claude Profiles</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>dev.local.ClaudeProfiles</string>
			<key>CFBundleURLSchemes</key><array><string>claudeprofiles</string></array>
		</dict>
	</array>
	<key>NSHumanReadableCopyright</key><string></string>
</dict>
</plist>
EOF

cp .build/release/ClaudeProfiles "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
echo "built: $APP (v$VERSION, build $BUILD)"
