// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hey-clawd",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(
            name: "hey-clawd",
            targets: ["HeyClawdApp"]
        ),
    ],
    dependencies: [
        // Phase 5.5: .dmg / .zip 安装走 Sparkle 自动更新。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "HeyClawdApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: ".",
            exclude: [
                ".ace-tool",
                ".build",
                ".claude",
                ".git",
                ".gitignore",
                "hey-clawd.xcodeproj",
                "Info.plist",
                "references",
                "test-bubble.sh",
                "Tests",
            ],
            sources: [
                "Sources",
            ],
            resources: [
                .copy("Resources/svg"),
                .copy("Resources/sounds"),
                .copy("Resources/icons"),
                .copy("hooks"),
                .copy("AppIcon.icns"),
            ]
        ),
        .testTarget(
            name: "HeyClawdAppTests",
            dependencies: [
                "HeyClawdApp",
            ],
            path: "Tests/HeyClawdAppTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
