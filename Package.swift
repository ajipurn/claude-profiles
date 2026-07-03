// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClaudeProfilesCore"),
        .executableTarget(name: "ClaudeProfiles", dependencies: ["ClaudeProfilesCore"]),
        .testTarget(name: "ClaudeProfilesCoreTests", dependencies: ["ClaudeProfilesCore"]),
    ]
)
