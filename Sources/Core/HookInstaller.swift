import Foundation

/// Registers Clawd hooks into Claude Code's ~/.claude/settings.json
/// by running the bundled hooks/install.js with Node.js.
/// Idempotent — safe to call on every launch.
enum HookInstaller {

    /// 所有 hook 安装脚本，按优先级排列。
    /// 每个脚本内部会检测对应工具是否已安装，未装的自动跳过。
    private static let installScripts = [
        "install.js",           // Claude Code
        "gemini-install.js",    // Gemini CLI
        "cursor-install.js",    // Cursor
        "codebuddy-install.js", // CodeBuddy (Copilot)
    ]

    /// Synchronous — call from a detached Task, not the main thread.
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

    private static func runNode(_ nodeBin: String, script: String, serverPort: Int?) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodeBin)
        var arguments = [script]
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

    // MARK: - Locate hooks directory

    private static func findHooksDir() -> String? {
        let fm = FileManager.default

        // Xcode .app bundle: Contents/Resources/hooks/
        if let resourceURL = Bundle.main.resourceURL {
            for sub in ["hooks", "Resources/hooks"] {
                let path = resourceURL.appendingPathComponent(sub).path
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent("install.js")) {
                    return path
                }
            }
        }

        #if SWIFT_PACKAGE
        if let moduleURL = Bundle.module.resourceURL {
            for sub in ["hooks", "Resources/hooks"] {
                let path = moduleURL.appendingPathComponent(sub).path
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent("install.js")) {
                    return path
                }
            }
        }
        #endif

        // Dev build: walk up from executable to find project root.
        let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        var dir = URL(fileURLWithPath: execPath).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("hooks").path
            if fm.fileExists(atPath: (candidate as NSString).appendingPathComponent("install.js")) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }

        return nil
    }
}
