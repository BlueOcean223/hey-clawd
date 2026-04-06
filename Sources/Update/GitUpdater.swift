import Foundation

struct GitUpdateCheckResult: Sendable {
    let localRevision: String
    let remoteRevision: String

    var isUpdateAvailable: Bool {
        localRevision != remoteRevision
    }
}

struct GitUpdateResult: Sendable {
    let packagesChanged: Bool
}

enum GitUpdaterError: LocalizedError {
    case repositoryNotFound
    case commandFailed(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case .repositoryNotFound:
            return "Git repository not found."
        case let .commandFailed(command, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? command : trimmed
        }
    }
}

final class GitUpdater: @unchecked Sendable {
    let repoRoot: URL?

    private let fileManager: FileManager
    private let trackedRemote = "origin"
    private let trackedBranch = "main"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        // 源码安装最稳定的锚点是编译时源文件路径；打包产物通常找不到 .git，自然会回退到 Sparkle。
        repoRoot = Self.findGitRoot(fileManager: fileManager)
    }

    var isAvailable: Bool {
        repoRoot != nil
    }

    func checkForUpdates() async throws -> GitUpdateCheckResult {
        guard let repoRoot else {
            throw GitUpdaterError.repositoryNotFound
        }

        _ = try runCommand(
            launchPath: "/usr/bin/git",
            arguments: ["fetch", trackedRemote, trackedBranch],
            currentDirectoryURL: repoRoot
        )

        let localRevision = try runCommand(
            launchPath: "/usr/bin/git",
            arguments: ["rev-parse", "HEAD"],
            currentDirectoryURL: repoRoot
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteRevision = try runCommand(
            launchPath: "/usr/bin/git",
            arguments: ["rev-parse", "\(trackedRemote)/\(trackedBranch)"],
            currentDirectoryURL: repoRoot
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return GitUpdateCheckResult(localRevision: localRevision, remoteRevision: remoteRevision)
    }

    func update() async throws -> GitUpdateResult {
        guard let repoRoot else {
            throw GitUpdaterError.repositoryNotFound
        }

        // 先记下依赖相关文件，只有真的变了才重新 resolve，避免每次 pull 都慢一轮。
        let packageFingerprintBefore = packageFingerprint(at: repoRoot)

        _ = try runCommand(
            launchPath: "/usr/bin/git",
            arguments: ["pull", "--ff-only", trackedRemote, trackedBranch],
            currentDirectoryURL: repoRoot
        )

        let packageFingerprintAfter = packageFingerprint(at: repoRoot)
        let packagesChanged = packageFingerprintBefore != packageFingerprintAfter

        if packagesChanged {
            _ = try runCommand(
                launchPath: "/usr/bin/xcrun",
                arguments: ["swift", "package", "resolve"],
                currentDirectoryURL: repoRoot
            )

            let projectPath = repoRoot.appendingPathComponent("hey-clawd.xcodeproj").path
            if fileManager.fileExists(atPath: projectPath) {
                _ = try runCommand(
                    launchPath: "/usr/bin/xcodebuild",
                    arguments: [
                        "-resolvePackageDependencies",
                        "-project", projectPath,
                        "-scheme", "hey-clawd",
                    ],
                    currentDirectoryURL: repoRoot
                )
            }
        }

        return GitUpdateResult(packagesChanged: packagesChanged)
    }

    private func packageFingerprint(at repoRoot: URL) -> [String: String] {
        [
            "Package.swift": fingerprint(for: repoRoot.appendingPathComponent("Package.swift")),
            "Package.resolved": fingerprint(for: repoRoot.appendingPathComponent("Package.resolved")),
            "XcodePackage.resolved": fingerprint(for: repoRoot.appendingPathComponent("hey-clawd.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")),
        ]
    }

    private func fingerprint(for fileURL: URL) -> String {
        guard let data = try? Data(contentsOf: fileURL) else {
            return "missing"
        }

        return String(data.count) + ":" + String(data.hashValue)
    }

    private func runCommand(
        launchPath: String,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: stdoutData, as: UTF8.self) + String(decoding: stderrData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let command = ([launchPath] + arguments).joined(separator: " ")
            throw GitUpdaterError.commandFailed(command: command, output: output)
        }

        return output
    }

    private static func findGitRoot(fileManager: FileManager) -> URL? {
        let candidates = [
            URL(fileURLWithPath: #filePath),
            Bundle.main.bundleURL,
        ]

        for candidate in candidates {
            guard let root = walkUpToGitRoot(from: candidate, fileManager: fileManager) else {
                continue
            }

            guard isExpectedRepository(at: root) else {
                continue
            }

            return root
        }

        return nil
    }

    private static func walkUpToGitRoot(from url: URL, fileManager: FileManager) -> URL? {
        let startDirectory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        var currentURL = startDirectory.standardizedFileURL

        while true {
            let gitDirectory = currentURL.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return nil
            }

            currentURL = parentURL
        }
    }

    private static func isExpectedRepository(at url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path, "remote", "get-url", "origin"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return false
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return false
        }

        let remoteURL = String(decoding: stdoutData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remoteURL.contains("hey-clawd")
    }
}
