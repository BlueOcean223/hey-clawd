import AppKit
import Foundation

enum FocusEditor: String, Sendable {
    case code
    case cursor
}

struct TerminalFocusTarget: Sendable {
    let pid: pid_t?
    let identity: FocusProcessIdentity?
    let isSourceVerified: Bool
    let pidChain: [pid_t]?
    let editor: FocusEditor?

    var isFocusable: Bool {
        pid != nil || editor != nil
    }
}

@MainActor
enum TerminalFocus {
    private static let fallbackAllowedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
    ]

    static func focus(_ target: TerminalFocusTarget, processInspector: ProcessInspecting = SystemProcessInspector.shared) {
        // 优先激活 hook 进程树验证过的 source_pid；未知终端不需要预先写进 bundle 白名单。
        if let pid = target.pid,
           target.isSourceVerified,
           focusVerifiedApplication(pid: pid, identity: target.identity, processInspector: processInspector) {
            return
        }

        // 老 hook 或缺少 agent_pid 的会话仍走保守白名单 fallback，避免任意本地 payload 激活任意应用。
        if let pid = target.pid, focusKnownApplication(pid: pid) {
            return
        }

        // 某些会话来自 VS Code / Cursor，source_pid 可能缺失或已经失效。
        // 这时退回到编辑器级激活，至少把对应应用带到前台。
        if let editor = target.editor {
            focusEditor(editor)
        }
    }

    @discardableResult
    private static func focusVerifiedApplication(
        pid: pid_t,
        identity: FocusProcessIdentity?,
        processInspector: ProcessInspecting
    ) -> Bool {
        guard
            let app = NSRunningApplication(processIdentifier: pid),
            !app.isTerminated,
            identity?.matches(app) == true || identity == nil && processInspector.isProcessAlive(pid)
        else {
            return false
        }

        return activate(app)
    }

    @discardableResult
    private static func focusKnownApplication(pid: pid_t) -> Bool {
        guard
            let app = NSRunningApplication(processIdentifier: pid),
            !app.isTerminated
        else {
            return false
        }

        guard let bundleID = app.bundleIdentifier,
              fallbackAllowedBundleIDs.contains(bundleID)
        else {
            return false
        }

        return activate(app)
    }

    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            return app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        }

        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    static func focusEditor(_ editor: FocusEditor) {
        let appName: String
        switch editor {
        case .code:
            appName = "Visual Studio Code"
        case .cursor:
            appName = "Cursor"
        }

        let script = "tell application \"\(appName)\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}
