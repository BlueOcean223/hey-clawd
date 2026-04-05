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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "HeyClawdApp",
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
            ],
            sources: [
                "Sources",
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
