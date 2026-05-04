import AppKit
import Foundation

/// 已知的图形化编辑器枚举，用于在缺乏可信 PID 时退化到 AppleScript 激活。
enum FocusEditor: String, Sendable {
    case code
    case cursor
}

/// 把焦点回切所需的全部线索打包：PID + 进程身份 + 是否经过 hook 端校验 + 编辑器 fallback。
/// `Session` 与 `SessionMenuSnapshot` 各自实现 `focusTarget` 计算属性来产出该结构。
struct TerminalFocusTarget: Sendable {
    let pid: pid_t?
    /// `pid` 对应进程的可执行身份指纹，激活前用于检测 PID 是否被 OS 复用给了别的进程。
    let identity: FocusProcessIdentity?
    /// 兼容旧会话快照字段；payload PID 不再用于放宽焦点白名单。
    let isSourceVerified: Bool
    /// agent → … → terminal 的祖先链，用于 fallback 校验。
    let pidChain: [pid_t]?
    let editor: FocusEditor?

    var isFocusable: Bool {
        pid != nil || editor != nil
    }
}

/// 把用户焦点带回到触发该会话的终端/编辑器。
///
/// 由 `MenuBuilder` 在用户点击会话子菜单时调用，也用于 `BubbleStack` 的"激活后再决策"路径。
/// 安全考虑：本地 PID 来自 `/state` payload，不能作为授权证据；这里只激活下方白名单内的
/// 已知终端/IDE，并在有进程指纹时额外检查 PID 是否被复用。
@MainActor
enum TerminalFocus {
    /// 保守白名单，覆盖项目积累的常见终端/IDE。
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

    /// 两段式回切策略：白名单 PID → 编辑器 AppleScript。
    static func focus(_ target: TerminalFocusTarget) {
        // `/state` payload 里的 PID 只能作为候选目标；实际激活必须落在保守白名单内。
        if let pid = target.pid,
           focusKnownApplication(pid: pid, identity: target.identity) {
            return
        }

        // 某些会话来自 VS Code / Cursor，source_pid 可能缺失或已经失效。
        // 这时退回到编辑器级激活，至少把对应应用带到前台。
        if let editor = target.editor {
            focusEditor(editor)
        }
    }

    /// fallback 路径：仅当 bundleID 落在白名单内才激活，限制 PID 复用造成的风险。
    @discardableResult
    private static func focusKnownApplication(pid: pid_t, identity: FocusProcessIdentity?) -> Bool {
        guard
            let app = NSRunningApplication(processIdentifier: pid),
            !app.isTerminated
        else {
            return false
        }

        if let identity, identity.hasStableFields, !identity.matches(app) {
            return false
        }

        guard let bundleID = app.bundleIdentifier,
              fallbackAllowedBundleIDs.contains(bundleID)
        else {
            return false
        }

        return activate(app)
    }

    /// macOS 14+ 用新签名以避免 `activateIgnoringOtherApps` 的 deprecation 警告，
    /// 老系统继续走兼容选项；两条路径都附带 `.activateAllWindows` 以便多窗口终端整体抬起。
    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            return app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        }

        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    /// 通过 AppleScript 直接告诉编辑器激活。
    /// 不走 `NSRunningApplication`，因为这条路径专门用于 PID 已不可用的场景。
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
