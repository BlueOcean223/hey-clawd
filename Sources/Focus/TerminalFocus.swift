import AppKit
import Foundation

enum FocusEditor: String, Sendable {
    case code
    case cursor
}

struct TerminalFocusTarget: Sendable {
    let pid: pid_t?
    let cwd: String?
    let editor: FocusEditor?
}

@MainActor
enum TerminalFocus {
    static func focus(_ target: TerminalFocusTarget) {
        // 先尝试直接按 PID 激活，成功率最高，也最接近用户当前那一个终端窗口。
        if let pid = target.pid, focusTerminal(pid: pid) {
            return
        }

        // 某些会话来自 VS Code / Cursor，source_pid 可能缺失或已经失效。
        // 这时退回到编辑器级激活，至少把对应应用带到前台。
        if let editor = target.editor {
            focusEditor(editor)
        }
    }

    @discardableResult
    static func focusTerminal(pid: pid_t) -> Bool {
        guard
            let app = NSRunningApplication(processIdentifier: pid),
            !app.isTerminated
        else {
            return false
        }

        return app.activate(options: [.activateIgnoringOtherApps])
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
