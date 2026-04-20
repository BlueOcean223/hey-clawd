import Foundation
import XCTest
@testable import HeyClawdApp

final class HookInstallerTests: XCTestCase {
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

    private func executablePath(in root: URL) -> String {
        root.appendingPathComponent("bin/hey-clawd", isDirectory: false).path
    }
}
