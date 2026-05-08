import Foundation
import XCTest
@testable import HeyClawdApp

final class HookInstallerTests: XCTestCase {
    func testHookTargetsIncludeCodexCLI() {
        XCTAssertTrue(HookInstaller.HookTarget.allCases.contains(.codex))
        XCTAssertEqual(HookInstaller.HookTarget.codex.rawValue, "codex-install.js")
        XCTAssertEqual(HookInstaller.HookTarget.codex.displayName, "Codex CLI")
    }

    func testBundledHooksIncludeCodexInstaller() throws {
        let hooksDir = try XCTUnwrap(HookInstaller.findHooksDir())
        let codexInstallerPath = URL(fileURLWithPath: hooksDir)
            .appendingPathComponent("codex-install.js", isDirectory: false)
            .path

        XCTAssertTrue(FileManager.default.fileExists(atPath: codexInstallerPath))
    }

    func testCodexLocalCleanupRemovesOnlyCodexHookEntries() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let hooksURL = root
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        try writeJSON([
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "*",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "\"/usr/bin/node\" \"/tmp/codex-hook.js\"",
                                "timeout": 10,
                            ],
                            [
                                "type": "command",
                                "command": "\"/usr/bin/node\" \"/tmp/user-hook.js\"",
                            ],
                        ],
                    ],
                ],
                "Stop": [
                    "matcher": "*",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\"/usr/bin/node\" \"/tmp/codex-hook.js\"",
                            "timeout": 10,
                        ],
                    ],
                ],
                "PermissionRequest": [
                    [
                        "matcher": "*",
                        "hooks": [
                            [
                                "type": "http",
                                "url": "https://example.com/permission",
                                "timeout": 30,
                            ],
                        ],
                    ],
                ],
            ],
        ], to: hooksURL)

        let result = HookInstaller.cleanupLocalSettingsForTesting(
            target: .codex,
            settingsPath: hooksURL.path
        )
        let settings = try readJSONObject(from: hooksURL)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [Any])
        let preToolUseEntry = try XCTUnwrap(preToolUse.first as? [String: Any])
        let remainingHooks = try XCTUnwrap(preToolUseEntry["hooks"] as? [[String: Any]])
        let permissionRequest = try XCTUnwrap(hooks["PermissionRequest"] as? [Any])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Removed: 2 hooks"))
        XCTAssertEqual(remainingHooks.count, 1)
        XCTAssertEqual(remainingHooks.first?["command"] as? String, "\"/usr/bin/node\" \"/tmp/user-hook.js\"")
        XCTAssertNil(hooks["Stop"])
        XCTAssertEqual(permissionRequest.count, 1)
    }

    func testFindHooksDir_returnsWorkspaceHooks_whenResourceURLInDerivedData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let derivedDataURL = root
            .appendingPathComponent("deriveddata", isDirectory: true)
            .appendingPathComponent("hey-clawd-XXX", isDirectory: true)
        let resourceURL = derivedDataURL
            .appendingPathComponent("Build/Products/Debug/hey-clawd.app/Contents/Resources", isDirectory: true)

        try writeInfoPlist(workspacePath: repoURL.path, to: derivedDataURL)
        try writeInstallScript(in: repoURL.appendingPathComponent("hooks", isDirectory: true))
        try writeInstallScript(in: resourceURL.appendingPathComponent("hooks", isDirectory: true))

        let hooksDir = HookInstaller.findHooksDir(
            resourceURL: resourceURL,
            moduleResourceURL: nil,
            executablePath: executablePath(in: root),
            fileManager: .default
        )

        XCTAssertEqual(hooksDir, repoURL.appendingPathComponent("hooks", isDirectory: true).path)
    }

    func testFindHooksDir_fallsThroughToBundle_whenWorkspaceHooksMissing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let derivedDataURL = root
            .appendingPathComponent("deriveddata", isDirectory: true)
            .appendingPathComponent("hey-clawd-XXX", isDirectory: true)
        let resourceURL = derivedDataURL
            .appendingPathComponent("Build/Products/Debug/hey-clawd.app/Contents/Resources", isDirectory: true)
        let bundleHooksURL = resourceURL.appendingPathComponent("hooks", isDirectory: true)

        try writeInfoPlist(workspacePath: repoURL.path, to: derivedDataURL)
        try writeInstallScript(in: bundleHooksURL)

        let hooksDir = HookInstaller.findHooksDir(
            resourceURL: resourceURL,
            moduleResourceURL: nil,
            executablePath: executablePath(in: root),
            fileManager: .default
        )

        XCTAssertEqual(hooksDir, bundleHooksURL.path)
    }

    func testFindHooksDir_returnsBundleHooks_whenNotInDerivedData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let resourceURL = root
            .appendingPathComponent("Applications/hey-clawd.app/Contents/Resources", isDirectory: true)
        let bundleHooksURL = resourceURL.appendingPathComponent("hooks", isDirectory: true)

        try writeInstallScript(in: bundleHooksURL)

        let hooksDir = HookInstaller.findHooksDir(
            resourceURL: resourceURL,
            moduleResourceURL: nil,
            executablePath: executablePath(in: root),
            fileManager: .default
        )

        XCTAssertEqual(hooksDir, bundleHooksURL.path)
    }

    func testFindHooksDir_usesWorkspacePathPointingToXcodeproj() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let projectURL = repoURL.appendingPathComponent("hey-clawd.xcodeproj", isDirectory: true)
        let derivedDataURL = root
            .appendingPathComponent("deriveddata", isDirectory: true)
            .appendingPathComponent("hey-clawd-XXX", isDirectory: true)
        let resourceURL = derivedDataURL
            .appendingPathComponent("Build/Products/Debug/hey-clawd.app/Contents/Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try writeInfoPlist(workspacePath: projectURL.path, to: derivedDataURL)
        try writeInstallScript(in: repoURL.appendingPathComponent("hooks", isDirectory: true))
        try writeInstallScript(in: resourceURL.appendingPathComponent("hooks", isDirectory: true))

        let hooksDir = HookInstaller.findHooksDir(
            resourceURL: resourceURL,
            moduleResourceURL: nil,
            executablePath: executablePath(in: root),
            fileManager: .default
        )

        XCTAssertEqual(hooksDir, repoURL.appendingPathComponent("hooks", isDirectory: true).path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HookInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeInfoPlist(workspacePath: String, to directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": workspacePath],
            format: .xml,
            options: 0
        )
        try data.write(to: directoryURL.appendingPathComponent("info.plist", isDirectory: false))
    }

    private func writeInstallScript(in hooksURL: URL) throws {
        try FileManager.default.createDirectory(at: hooksURL, withIntermediateDirectories: true)
        try Data().write(to: hooksURL.appendingPathComponent("install.js", isDirectory: false))
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func readJSONObject(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func executablePath(in root: URL) -> String {
        root.appendingPathComponent("bin/hey-clawd", isDirectory: false).path
    }
}
