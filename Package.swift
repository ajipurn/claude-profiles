// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    platforms: [.macOS(.v13)],
    targets: [
        // Vendored zstd 1.5.7 (decompress side only, BSD) — Claude Desktop's
        // HTTP cache stores response bodies zstd-compressed and macOS ships no
        // system decoder. Assembly is skipped for portability.
        .target(
            name: "CZstd",
            exclude: ["LICENSE"],
            cSettings: [
                .headerSearchPath("lib"),
                .headerSearchPath("lib/common"),
                .define("ZSTD_DISABLE_ASM"),
            ]
        ),
        .target(name: "ClaudeProfilesCore", dependencies: ["CZstd"]),
        .executableTarget(name: "ClaudeProfiles", dependencies: ["ClaudeProfilesCore"]),
        .testTarget(name: "ClaudeProfilesCoreTests", dependencies: ["ClaudeProfilesCore"]),
    ]
)
