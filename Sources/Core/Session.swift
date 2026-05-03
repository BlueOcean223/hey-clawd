import Foundation

/// 一次 IDE/CLI 会话在 StateMachine 中的可变记录。
///
/// 每个 Hook 客户端（Claude Code、Codex、Cursor…）每个工程目录会绑定一个 `id`，
/// 后续 PreToolUse/PostToolUse 等事件都通过相同 id 找到这条记录并更新状态。
/// 字段中的 `sourcePid`/`agentPid`/`pidChain` 由 hook 携带上来，用于
/// `TerminalFocus` 在用户回到 dock 时把焦点带回到对应终端。
struct Session: Sendable {
    let id: String
    var state: PetState
    var updatedAt: Date
    /// 当前应当渲染的 SVG 文件名；nil 表示沿用 `state` 的默认 SVG。
    var displaySvg: String?
    /// 触发该会话的本地进程 PID（通常是终端，也可能是宿主 IDE）。
    var sourcePid: pid_t?
    /// `sourcePid` 对应进程的可执行身份指纹，用于在激活前防止 PID 被复用。
    var sourceProcessIdentity: FocusProcessIdentity?
    /// 为 true 表示 hook 端已通过 agent_pid → 父进程链验证过 sourcePid 的合法性，
    /// 可放宽白名单（否则只激活 `fallbackAllowedBundleIDs` 内的已知终端）。
    var sourcePidVerified: Bool
    /// CLI agent 自身的 PID，用于反查 PID 链以判断终端归属。
    var agentPid: pid_t?
    /// 从 agent 进程一路向上的父进程 PID 链，验证失败时也用于 fallback 匹配。
    var pidChain: [pid_t]?
    var cwd: String?
    var editor: FocusEditor?
    var agentId: String?
    /// headless 会话不展示在菜单中，例如 CI/批处理触发的 hook。
    var headless: Bool

    /// 把会话中和「焦点回切」相关的字段打包成 `TerminalFocus` 的输入参数。
    var focusTarget: TerminalFocusTarget {
        TerminalFocusTarget(
            pid: sourcePid,
            identity: sourceProcessIdentity,
            isSourceVerified: sourcePidVerified,
            pidChain: pidChain,
            editor: editor
        )
    }
}

/// `Session` 的不可变快照，专供 Tray/Menu 在 `@MainActor` 外读取。
/// 字段语义完全对齐 `Session`，仅去掉 `displaySvg`/`headless` 等菜单不需要的内容。
struct SessionMenuSnapshot: Sendable {
    let id: String
    let state: PetState
    let updatedAt: Date
    let sourcePid: pid_t?
    let sourceProcessIdentity: FocusProcessIdentity?
    let sourcePidVerified: Bool
    let agentPid: pid_t?
    let pidChain: [pid_t]?
    let cwd: String?
    let editor: FocusEditor?
    let agentId: String?

    var focusTarget: TerminalFocusTarget {
        TerminalFocusTarget(
            pid: sourcePid,
            identity: sourceProcessIdentity,
            isSourceVerified: sourcePidVerified,
            pidChain: pidChain,
            editor: editor
        )
    }
}
