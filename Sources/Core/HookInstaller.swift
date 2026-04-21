import Foundation

/// Registers Clawd hooks into Claude Code's ~/.claude/settings.json
/// by running the bundled hooks/install.js with Node.js.
/// Idempotent — safe to call on every launch.
enum HookInstaller {
    private static let defaultServerPort = 23333
    private static let serverPortCount = 5
    private static let clawdPermissionURLs = Set(
        (0..<serverPortCount).map { "http://127.0.0.1:\(defaultServerPort + $0)/permission" }
    )

    private struct LocalCleanupSpec {
        let settingsPath: String
        let cleanedMessage: String
        let missingMessage: String
        let emptyMessage: String
        let commandMarkers: [String]
        let permissionURLs: Set<String>
    }

    private struct LocalDirectoryCleanupSpec {
        let directoryPath: String
        let markerFileName: String
        let cleanedMessage: String
        let missingMessage: String
        let unmanagedMessage: String
    }

    enum HookTarget: String, CaseIterable {
        case claudeCode = "install.js"
        case gemini = "gemini-install.js"
        case cursor = "cursor-install.js"
        case codeBuddy = "codebuddy-install.js"
        case pi = "pi-install.js"

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .gemini: return "Gemini CLI"
            case .cursor: return "Cursor"
            case .codeBuddy: return "CodeBuddy"
            case .pi: return "Pi"
            }
        }
    }

    /// 所有 hook 安装脚本，按优先级排列。
    /// 每个脚本内部会检测对应工具是否已安装，未装的自动跳过。
    private static let installScripts = HookTarget.allCases.map(\.rawValue)

    /// Register a single target's hooks.
    static func register(target: HookTarget, serverPort: Int? = nil) -> (success: Bool, output: String) {
        guard let nodeBin = resolveNodeBin() else {
            return (false, "Node.js not found.\nInstall Node.js first.")
        }
        guard let hooksDir = findHooksDir() else {
            return (false, "hooks/ not found in app bundle.")
        }

        let scriptPath = (hooksDir as NSString).appendingPathComponent(target.rawValue)
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            return (false, "\(target.rawValue) not found.")
        }

        return runNode(nodeBin, script: scriptPath, serverPort: serverPort)
    }

    /// Register all hooks. Synchronous — call from a detached Task, not the main thread.
    static func register(serverPort: Int? = nil) -> (success: Bool, output: String) {
        guard let nodeBin = resolveNodeBin() else {
            return (false, "Node.js not found.\nInstall Node.js first.")
        }
        guard let hooksDir = findHooksDir() else {
            return (false, "hooks/ not found in app bundle.")
        }

        var allOutput: [String] = []
        var allSuccess = true

        for script in installScripts {
            let scriptPath = (hooksDir as NSString).appendingPathComponent(script)
            guard FileManager.default.fileExists(atPath: scriptPath) else { continue }

            let (success, output) = runNode(nodeBin, script: scriptPath, serverPort: serverPort)
            if !output.isEmpty { allOutput.append(output) }
            if !success { allSuccess = false }
        }

        let combined = allOutput.joined(separator: "\n\n")
        return (allSuccess, combined.isEmpty ? "No hooks installed." : combined)
    }

    /// Unregister a single target's hooks.
    static func unregister(target: HookTarget, serverPort: Int? = nil) -> (success: Bool, output: String) {
        if let nodeBin = resolveNodeBin() {
            guard let hooksDir = findHooksDir() else {
                return (false, "hooks/ not found in app bundle.")
            }

            let scriptPath = (hooksDir as NSString).appendingPathComponent(target.rawValue)
            guard FileManager.default.fileExists(atPath: scriptPath) else {
                return (false, "\(target.rawValue) not found.")
            }

            return runNode(nodeBin, script: scriptPath, serverPort: serverPort, extraArgs: ["--uninstall"])
        }

        return unregisterLocally(target: target, noteNodeMissing: true)
    }

    /// Unregister all hooks. Synchronous — call from a detached Task.
    static func unregister(serverPort: Int? = nil) -> (success: Bool, output: String) {
        if let nodeBin = resolveNodeBin() {
            guard let hooksDir = findHooksDir() else {
                return (false, "hooks/ not found in app bundle.")
            }

            var allOutput: [String] = []
            var allSuccess = true

            for script in installScripts {
                let scriptPath = (hooksDir as NSString).appendingPathComponent(script)
                guard FileManager.default.fileExists(atPath: scriptPath) else { continue }

                let (success, output) = runNode(nodeBin, script: scriptPath, serverPort: serverPort, extraArgs: ["--uninstall"])
                if !output.isEmpty { allOutput.append(output) }
                if !success { allSuccess = false }
            }

            let combined = allOutput.joined(separator: "\n\n")
            return (allSuccess, combined.isEmpty ? "No hooks removed." : combined)
        }

        return unregisterAllLocally(noteNodeMissing: true)
    }

    private static func runNode(_ nodeBin: String, script: String, serverPort: Int?, extraArgs: [String] = []) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodeBin)
        var arguments = [script] + extraArgs
        if let serverPort {
            arguments.append(contentsOf: ["--port", String(serverPort)])
        }
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }

        // Read before waitUntilExit to avoid pipe-buffer deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, output)
    }

    // MARK: - Node resolution (mirrors hooks/server-config.js resolveNodeBin)

    private static func resolveNodeBin() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.local/bin/node",
            "/usr/bin/node",
        ]

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }

        // Fallback: login+interactive shell to resolve nvm/fnm/etc.
        for shell in ["/bin/zsh", "/bin/bash"] where fm.isExecutableFile(atPath: shell) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: shell)
            proc.arguments = ["-lic", "which node"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice

            do {
                try proc.run()
            } catch { continue }

            let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { continue }

            // Interactive shells may print prompts; take last absolute path.
            for line in raw.split(separator: "\n").reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/") { return trimmed }
            }
        }

        return nil
    }

    // MARK: - Local cleanup fallback

    private static func unregisterLocally(target: HookTarget, noteNodeMissing: Bool) -> (success: Bool, output: String) {
        let result = cleanupLocalSettings(for: target)
        if noteNodeMissing {
            return (
                result.success,
                "Node.js not found.\nCleaning local hook settings directly.\n\n\(result.output)"
            )
        }
        return result
    }

    private static func unregisterAllLocally(noteNodeMissing: Bool) -> (success: Bool, output: String) {
        var outputs: [String] = []
        var allSuccess = true

        for target in HookTarget.allCases {
            let result = cleanupLocalSettings(for: target)
            if !result.output.isEmpty {
                outputs.append(result.output)
            }
            if !result.success {
                allSuccess = false
            }
        }

        let combined = outputs.joined(separator: "\n\n")
        let body = combined.isEmpty ? "No hooks removed." : combined
        if noteNodeMissing {
            return (
                allSuccess,
                "Node.js not found.\nCleaning local hook settings directly.\n\n\(body)"
            )
        }
        return (allSuccess, body)
    }

    private static func cleanupLocalSettings(for target: HookTarget) -> (success: Bool, output: String) {
        if target == .pi {
            return cleanupLocalDirectory(for: localDirectoryCleanupSpec())
        }

        let spec = localCleanupSpec(for: target)
        let settingsURL = URL(fileURLWithPath: spec.settingsPath)

        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            if isMissingFileError(error) {
                return (true, spec.missingMessage)
            }
            return (false, "Failed to read \(settingsURL.lastPathComponent): \(error.localizedDescription)")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return (false, "Failed to parse \(settingsURL.lastPathComponent): \(error.localizedDescription)")
        }

        guard var settings = object as? [String: Any] else {
            return (false, "Failed to parse \(settingsURL.lastPathComponent): root object is not a JSON object.")
        }

        guard var hooks = settings["hooks"] as? [String: Any] else {
            return (true, spec.emptyMessage)
        }

        var totalRemoved = 0
        var changed = false

        for event in Array(hooks.keys) {
            let normalized = normalizeHookEntries(hooks[event])
            guard var entries = normalized.entries else { continue }
            if normalized.changed {
                hooks[event] = entries
                changed = true
            }

            let commandResult = removeMatchingCommandHooks(entries, markers: spec.commandMarkers)
            if commandResult.changed {
                entries = commandResult.entries
                hooks[event] = entries
                totalRemoved += commandResult.removed
                changed = true
            }

            let httpResult = removeMatchingHTTPHooks(entries, urls: spec.permissionURLs)
            if httpResult.changed {
                entries = httpResult.entries
                hooks[event] = entries
                totalRemoved += httpResult.removed
                changed = true
            }

            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            }
        }

        if changed {
            settings["hooks"] = hooks
            do {
                try writeJSONAtomic(settings, to: settingsURL)
            } catch {
                return (false, "Failed to write \(settingsURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return (true, "\(spec.cleanedMessage)\n  Removed: \(totalRemoved) hooks")
    }

    private static func localCleanupSpec(for target: HookTarget) -> LocalCleanupSpec {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch target {
        case .claudeCode:
            let settingsPath = "\(home)/.claude/settings.json"
            return LocalCleanupSpec(
                settingsPath: settingsPath,
                cleanedMessage: "Clawd hooks cleaned from \(settingsPath)",
                missingMessage: "No settings.json found — nothing to clean.",
                emptyMessage: "No hooks in settings.json — nothing to clean.",
                commandMarkers: ["clawd-hook.js", "auto-start.js", "auto-start.sh"],
                permissionURLs: clawdPermissionURLs
            )
        case .gemini:
            let settingsPath = "\(home)/.gemini/settings.json"
            return LocalCleanupSpec(
                settingsPath: settingsPath,
                cleanedMessage: "Clawd Gemini hooks cleaned from \(settingsPath)",
                missingMessage: "No ~/.gemini/settings.json found — nothing to clean.",
                emptyMessage: "No hooks in settings.json — nothing to clean.",
                commandMarkers: ["gemini-hook.js"],
                permissionURLs: []
            )
        case .cursor:
            let settingsPath = "\(home)/.cursor/hooks.json"
            return LocalCleanupSpec(
                settingsPath: settingsPath,
                cleanedMessage: "Clawd Cursor hooks cleaned from \(settingsPath)",
                missingMessage: "No ~/.cursor/hooks.json found — nothing to clean.",
                emptyMessage: "No hooks in hooks.json — nothing to clean.",
                commandMarkers: ["cursor-hook.js"],
                permissionURLs: []
            )
        case .codeBuddy:
            let settingsPath = "\(home)/.codebuddy/settings.json"
            return LocalCleanupSpec(
                settingsPath: settingsPath,
                cleanedMessage: "Clawd CodeBuddy hooks cleaned from \(settingsPath)",
                missingMessage: "No ~/.codebuddy/settings.json found — nothing to clean.",
                emptyMessage: "No hooks in settings.json — nothing to clean.",
                commandMarkers: ["codebuddy-hook.js"],
                permissionURLs: clawdPermissionURLs
            )
        case .pi:
            fatalError("Pi uses localDirectoryCleanupSpec(), not localCleanupSpec(for:)")
        }
    }

    private static func localDirectoryCleanupSpec() -> LocalDirectoryCleanupSpec {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directoryPath = "\(home)/.pi/agent/extensions/hey-clawd"
        return LocalDirectoryCleanupSpec(
            directoryPath: directoryPath,
            markerFileName: ".clawd-managed.json",
            cleanedMessage: "Clawd Pi extension cleaned from \(directoryPath)",
            missingMessage: "No ~/.pi/agent/extensions/hey-clawd found — nothing to clean.",
            unmanagedMessage: "Pi extension directory exists but is not managed by hey-clawd — skipping cleanup."
        )
    }

    private static func cleanupLocalDirectory(for spec: LocalDirectoryCleanupSpec) -> (success: Bool, output: String) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: spec.directoryPath) else {
            return (true, spec.missingMessage)
        }

        let markerPath = URL(fileURLWithPath: spec.directoryPath).appendingPathComponent(spec.markerFileName).path
        guard
            let markerData = try? Data(contentsOf: URL(fileURLWithPath: markerPath)),
            let object = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
            let app = object["app"] as? String,
            let integration = object["integration"] as? String,
            app == "hey-clawd",
            integration == "pi"
        else {
            return (true, spec.unmanagedMessage)
        }

        do {
            try fileManager.removeItem(atPath: spec.directoryPath)
            return (true, "\(spec.cleanedMessage)\n  Removed: 1 extension directory")
        } catch {
            return (false, "Failed to remove hey-clawd Pi extension: \(error.localizedDescription)")
        }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT {
            return true
        }
        return false
    }

    private static func normalizeHookEntries(_ value: Any?) -> (entries: [Any]?, changed: Bool) {
        if let entries = value as? [Any] {
            return (entries, false)
        }
        if let entry = value as? [String: Any] {
            return ([entry], true)
        }
        return (nil, false)
    }

    private static func removeMatchingCommandHooks(_ entries: [Any], markers: [String]) -> (entries: [Any], removed: Int, changed: Bool) {
        guard !markers.isEmpty else {
            return (entries, 0, false)
        }

        let matches: (String) -> Bool = { command in
            markers.contains { command.contains($0) }
        }

        var removed = 0
        var changed = false
        var nextEntries: [Any] = []

        for item in entries {
            guard let entry = item as? [String: Any] else {
                nextEntries.append(item)
                continue
            }

            var entryChanged = false
            var nextEntry = entry

            if let command = entry["command"] as? String, matches(command) {
                nextEntry.removeValue(forKey: "command")
                removed += 1
                changed = true
                entryChanged = true
            }

            if let hooks = entry["hooks"] as? [Any] {
                let nextHooks = hooks.filter { hookItem in
                    guard
                        let hook = hookItem as? [String: Any],
                        let command = hook["command"] as? String
                    else {
                        return true
                    }
                    if !matches(command) {
                        return true
                    }
                    removed += 1
                    changed = true
                    entryChanged = true
                    return false
                }

                if nextHooks.isEmpty {
                    nextEntry.removeValue(forKey: "hooks")
                } else {
                    nextEntry["hooks"] = nextHooks
                }
            }

            if !entryChanged {
                nextEntries.append(entry)
                continue
            }

            let hasCommand = nextEntry["command"] is String
            let hasHooks = nextEntry["hooks"] is [Any]
            if !hasCommand && !hasHooks {
                continue
            }

            nextEntries.append(nextEntry)
        }

        return (nextEntries, removed, changed)
    }

    private static func removeMatchingHTTPHooks(_ entries: [Any], urls: Set<String>) -> (entries: [Any], removed: Int, changed: Bool) {
        guard !urls.isEmpty else {
            return (entries, 0, false)
        }

        var removed = 0
        var changed = false
        var nextEntries: [Any] = []

        for item in entries {
            guard let entry = item as? [String: Any] else {
                nextEntries.append(item)
                continue
            }

            var entryChanged = false
            var nextEntry = entry

            if
                let type = entry["type"] as? String,
                type == "http",
                let url = entry["url"] as? String,
                urls.contains(url)
            {
                nextEntry.removeValue(forKey: "type")
                nextEntry.removeValue(forKey: "url")
                nextEntry.removeValue(forKey: "timeout")
                removed += 1
                changed = true
                entryChanged = true
            }

            if let hooks = entry["hooks"] as? [Any] {
                let nextHooks = hooks.filter { hookItem in
                    guard
                        let hook = hookItem as? [String: Any],
                        let type = hook["type"] as? String,
                        type == "http",
                        let url = hook["url"] as? String
                    else {
                        return true
                    }
                    if !urls.contains(url) {
                        return true
                    }
                    removed += 1
                    changed = true
                    entryChanged = true
                    return false
                }

                if nextHooks.isEmpty {
                    nextEntry.removeValue(forKey: "hooks")
                } else {
                    nextEntry["hooks"] = nextHooks
                }
            }

            if !entryChanged {
                nextEntries.append(entry)
                continue
            }

            let hasTopLevelHTTP = (nextEntry["type"] as? String) == "http" && nextEntry["url"] is String
            let hasCommand = nextEntry["command"] is String
            let hasHooks = nextEntry["hooks"] is [Any]
            if !hasTopLevelHTTP && !hasCommand && !hasHooks {
                continue
            }

            nextEntries.append(nextEntry)
        }

        return (nextEntries, removed, changed)
    }

    private static func writeJSONAtomic(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var output = data
        output.append(0x0a)
        try output.write(to: url, options: .atomic)
    }

    // MARK: - Locate hooks directory

    static func findHooksDir() -> String? {
        findHooksDir(
            resourceURL: Bundle.main.resourceURL,
            moduleResourceURL: moduleResourceURLOrNil(),
            executablePath: Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0],
            fileManager: .default
        )
    }

    static func findHooksDir(
        resourceURL: URL?,
        moduleResourceURL: URL?,
        executablePath: String,
        fileManager: FileManager
    ) -> String? {
        if let path = hooksDirFromDerivedData(resourceURL: resourceURL, fileManager: fileManager) {
            return path
        }

        if let path = bundledHooksDir(resourceURL: resourceURL, fileManager: fileManager) {
            return path
        }

        if let path = bundledHooksDir(resourceURL: moduleResourceURL, fileManager: fileManager) {
            return path
        }

        return hooksDirFromExecutable(executablePath: executablePath, fileManager: fileManager)
    }

    private static func moduleResourceURLOrNil() -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.resourceURL
        #else
        return nil
        #endif
    }

    private static func hooksDirFromDerivedData(resourceURL: URL?, fileManager: FileManager) -> String? {
        guard var dir = resourceURL?.resolvingSymlinksInPath() else { return nil }

        for _ in 0..<12 {
            let plistURL = dir.appendingPathComponent("info.plist", isDirectory: false)
            if let workspacePath = workspacePath(from: plistURL, fileManager: fileManager) {
                let hooksURL = workspaceHooksURL(for: workspacePath)
                if hasInstallScript(in: hooksURL, fileManager: fileManager) {
                    return hooksURL.path
                }
            }

            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }

        return nil
    }

    private static func workspacePath(from plistURL: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: plistURL.path) else { return nil }
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["WorkspacePath"] as? String
    }

    private static func workspaceHooksURL(for workspacePath: String) -> URL {
        var workspaceURL = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath()
        if workspaceURL.pathExtension == "xcodeproj" || workspaceURL.pathExtension == "xcworkspace" {
            workspaceURL = workspaceURL.deletingLastPathComponent()
        }
        return workspaceURL.appendingPathComponent("hooks", isDirectory: true)
    }

    private static func bundledHooksDir(resourceURL: URL?, fileManager: FileManager) -> String? {
        guard let resourceURL else { return nil }

        for sub in ["hooks", "Resources/hooks"] {
            let hooksURL = resourceURL.appendingPathComponent(sub, isDirectory: true)
            if hasInstallScript(in: hooksURL, fileManager: fileManager) {
                return hooksURL.path
            }
        }

        return nil
    }

    private static func hooksDirFromExecutable(executablePath: String, fileManager: FileManager) -> String? {
        var dir = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            let hooksURL = dir.appendingPathComponent("hooks", isDirectory: true)
            if hasInstallScript(in: hooksURL, fileManager: fileManager) {
                return hooksURL.path
            }
            dir = dir.deletingLastPathComponent()
        }

        return nil
    }

    private static func hasInstallScript(in hooksURL: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: hooksURL.appendingPathComponent("install.js", isDirectory: false).path)
    }
}
