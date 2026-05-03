# Claude Code 集成原理

> Clawd 桌宠如何感知 Claude Code 的会话状态，以及权限气泡（Permission Bubble）的完整工作链路。

---

## 架构总览

```
Claude Code 进程
  ├─ command hook (clawd-hook.js)
  │    └─ POST /state → HTTPServer → StateMachine → 桌宠动画切换
  │
  └─ HTTP hook (PermissionRequest)
       └─ POST /permission → HTTPServer → BubbleStack → 气泡 UI
                                                  ↓
                                           用户点击 Allow/Deny
                                                  ↓
                                         HTTP 响应返回 Claude Code
```

**核心文件**：
- `hooks/clawd-hook.js` — 命令 hook，映射生命周期事件到桌宠状态
- `hooks/install.js` — hook 安装器，注册命令 hook + HTTP hook
- `Sources/Core/HTTPServer.swift` — HTTP 服务器，处理 /state 和 /permission
- `Sources/Bubble/BubbleStack.swift` — 气泡队列管理、显示和清理
- `Sources/Bubble/BubbleView.swift` — 气泡 UI（SwiftUI）
- `Sources/App/AppDelegate.swift` — 事件路由和权限气泡入口

---

## 两条集成通道

### 通道 1：状态感知（command hook → /state）

单向通知，Claude Code 的生命周期事件触发桌宠动画切换。

`clawd-hook.js` 的 `EVENT_TO_STATE` 映射：

| Claude Code Event | PetState | 说明 |
|-------------------|----------|------|
| `SessionStart` | `.idle` | 会话开始 |
| `SessionEnd` | `.sleeping` | 会话结束（/clear 时映射为 `.sweeping`） |
| `UserPromptSubmit` | `.thinking` | 用户提交 prompt |
| `PreToolUse` | `.working` | 工具即将执行 |
| `PostToolUse` | `.working` | 工具执行完毕 |
| `PostToolUseFailure` | `.working` | 工具执行失败（中途失败由 agent 自适应处理，保持 working；真正任务失败走 `StopFailure`） |
| `PostToolBatch` | `.working` | 工具批次完成，用于终端 deny-with-message 后的残留气泡匹配 |
| `Stop` | `.attention` | 回合结束，等待输入 |
| `StopFailure` | `.error` | 停止失败 |
| `SubagentStart` | `.juggling` | 子代理启动 |
| `SubagentStop` | `.working` | 子代理结束 |
| `PreCompact` | `.sweeping` | 上下文压缩开始 |
| `PostCompact` | `.attention` | 上下文压缩完毕 |
| `Notification` | `.notification` | 通知 |
| `Elicitation` | `.notification` | 引出式提问 |
| `WorktreeCreate` | `.carrying` | 工作树创建 |

**注册方式**：`install.js` 将 `clawd-hook.js` 注册为 `~/.claude/settings.json` 中的 command hook。版本检测（`VERSIONED_HOOKS`）确保 `PreCompact`、`PostCompact`、`StopFailure` 仅在 Claude Code ≥ 对应版本时注册。

**进程树遍历**：`clawd-hook.js` 中的 `getStablePid()` 在 `SessionStart` 时向上遍历 8 层进程链，找到宿主终端 PID（如 Terminal、iTerm2、Ghostty 等），用于后续的跳转焦点和 session 存活检测。同时检测 VS Code / Cursor 编辑器和 headless（`-p`/`--print`）模式。

### 通道 2：权限审核（HTTP hook → /permission）

双向协议，Claude Code 需要用户批准工具执行时走此通道。

**注册方式**：`install.js` 注册 HTTP hook：
```json
{
  "PermissionRequest": [{
    "type": "http",
    "url": "http://127.0.0.1:23333/permission",
    "timeout": 600
  }]
}
```

**完整链路**：

```
1. Claude Code 需要权限 → POST /permission (HTTP hook, body 含 tool_name/tool_input/session_id/suggestions)
2. HTTPServer 收到请求 → 创建 PendingPermissionRequest（内含 CheckedContinuation）
3. ConnectionPermissionTracker.attach(request) → 关联断连检测
4. monitorDisconnect 启动 → 循环 receive 监听 TCP EOF/RST
5. AppDelegate.presentPermissionBubble(request)
   ├─ passthrough 检测 → TaskCreate/TaskUpdate 等直接 auto-allow
   ├─ DND 模式 → undecided，让 Claude Code 回退到终端提示
   ├─ 隐藏气泡 → undecided，让 Claude Code 回退到终端提示
   └─ 正常 → BubbleStack.enqueue → 创建 BubbleWindow 展示气泡
6. 用户点击 Allow / Deny / Always allow in this session
   → resolveBubble → removeBubble(关窗 + 回传决策)
   → PendingPermissionRequest.respond → resume continuation
   → HTTP 响应以 hookSpecificOutput 格式返回给 Claude Code
7. Claude Code 收到决策 → 执行或取消工具
```

**HTTP 响应格式**（Claude Code 要求 `hookSpecificOutput` 包装）：
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedPermissions": [...]
    }
  }
}
```

---

## 气泡清理机制

气泡有五条关闭路径：

| 路径 | 触发条件 | 代码位置 |
|------|----------|----------|
| **用户决策** | 点击 Allow / Deny / Always allow in this session | `BubbleStack.resolveBubble` → `removeBubble(respondingWith: result)` |
| **手动关闭** | 点击右上角 X，交回 Claude Code 终端侧决策 | `BubbleStack.enqueue` → `removeBubble(respondingWith: .undecided)` |
| **断连检测** | Claude Code 关闭 /permission TCP 连接（终端 Deny 时会触发） | `monitorDisconnect` → `cancelPendingPermission` → `removeBubble(respondingWith: nil)` |
| **工具完成唯一匹配自动关闭** | 终端侧已处理权限但 Claude 未关闭 TCP；`PostToolUse` / `PostToolUseFailure` / `PostToolBatch` 的 hash 唯一锁定一个待决气泡时关闭 | `AppDelegate.autoDismissBubbleIfTerminalApproved` → `BubbleStack.dismissBubbleMatchingTerminalApproval` |
| **5 分钟超时兜底** | 气泡入栈后 5 分钟仍未决策且未被任何路径关闭 | `PendingPermissionRequest` 内置 timer → 自动 `.undecided` |
### Passthrough 工具

以下工具自动批准，不弹气泡（`BubbleStack.passthroughTools`）：

```
TaskCreate, TaskUpdate, TaskGet, TaskList, TaskStop, TaskOutput
```

这些是 Claude Code 的任务管理工具，频繁触发且无安全风险。

---

## 已知局限与困难

### 1. 终端批准后气泡残留（长时间 Bash 场景）

**现象**：用户在终端（而非气泡）点击 Allow 后，气泡不消失。对于长时间运行的 Bash 命令或 MCP 工具调用（1-2 分钟+），气泡会一直挂在屏幕上。

**根因**：当用户在终端审批时，Claude Code 不一定会主动关闭 /permission HTTP 连接。连接仍然存活，断连检测无法触发。另一方面，`PermissionRequest` payload 没有 `tool_use_id`，无法和后续 `PostToolUse` 精确关联。同一 session 里还可能有并行 subagent/tool 事件，所以 hey-clawd 不能安全地靠生命周期事件去猜"这个气泡已经解决了"。

**典型复现条件**：
1. 工具触发 Bash 或 MCP 权限（不在 passthrough 列表内）
2. 用户手通常已在终端上，习惯直接终端 Allow
3. 执行时间长（1-2 min+），放大了残留时间

**与 d153dee 的关系**：`d153dee` 修复的是 `ConnectionPermissionTracker` 的 check-then-act 竞态——断连信号在 `attach()` 之前到达导致气泡变孤儿。那个问题已解决。此处的问题是**断连根本没有发生**，属于不同的缺口。

**兜底策略**：在气泡右上角保留手动关闭按钮（×）。手动关闭返回 `undecided`，HTTP 层表现为 503；Claude Code 的 HTTP hook 语义把非 2xx 当作 non-blocking error，因此终端侧已有决策仍是事实来源。

### 2. 启发式事件 dismiss 的正确性风险（已通过受控匹配化解）

**背景**：曾考虑通过监听 /state 事件（如检测到同 session 的 `PostToolUse` 或 `working` 状态）来主动 dismiss 气泡。

**为何当时被否**：
- /state 事件中没有 tool_id 字段，无法精确关联"哪个事件对应哪个 permission 请求"
- 同一 session 可能有并行事件（`SubagentStop` 等），噪声事件会导致**未授权的气泡被错误 dismiss**
- 一旦气泡被误 dismiss，用户丧失 deny 能力，而 /permission 连接仍挂起，Claude Code 干等

**当前的安全方案**：通过观测实验确认 `PostToolUse` 与 `PermissionRequest` 之间 `tool_input` 的 SHA-256 哈希在常见 Bash / Write / MCP 调用上保持稳定（详见 [permission-match-key-spec](../permission-match-key-spec.md)），可作为可靠匹配键。`PostToolBatch` 使用同一 hash 处理终端拒绝且附带说明的残留场景。新机制的硬约束：

- 只对 `PostToolUse` / `PostToolUseFailure` / `PostToolBatch` 触发
- `agent_id` 必须是 `claude-code`
- `(session_id, tool_name, tool_input_hash)` 必须**唯一锁定**一个待决气泡
- 多匹配 → **不关**任何气泡，让用户手动决定
- 永远响应 `.undecided`，绝不替用户 allow / deny
- 不在 `PreToolUse / Stop / SessionEnd / UserPromptSubmit / Notification` 上做关闭

正确性 > 便利性的原则没有动；只是有了 hash 之后能在不违反原则的前提下覆盖大部分残留场景。同时为 `PendingPermissionRequest` 加 5 分钟超时兜底，覆盖 `PostToolUse` 也未到达的边缘场景。

### 3. Session always allow

气泡只暴露三个主动作：Allow、Deny、Always allow in this session。`permission_suggestions` 仍会被解析，但不会逐条展示成多个按钮。

- Allow：只批准本次请求，不带 `updatedPermissions`
- Deny：拒绝本次请求
- Always allow in this session：把有效 `addRules` / `addDirectories` 聚合成 `destination: "session"` 的 `updatedPermissions` 条目

对于 `curl | python3` 这类 compound Bash，Claude Code 可能给多个 `addRules` suggestion；对于 `/tmp` 等工作目录外路径，可能给 `addDirectories` suggestion。hey-clawd 会把它们合并到一个 session-only allow 动作里，不写 `localSettings` / `projectSettings` / `userSettings`。

`setMode`、空 `rules` / `directories`、非 allow 行为不会进入这个按钮，避免把"本会话总是允许"误变成权限模式切换或无效持久化。

#### 附加信息边界

Claude Code 终端 UI 的 Yes / No 都可以附带说明；本机 2.1.119 实现里，Yes 说明走内部 `acceptFeedback`，会被追加到工具结果后面给 Claude。

HTTP `PermissionRequest` hook 暴露的字段更窄：`decision.message` 只对 `behavior: "deny"` 生效，会作为拒绝原因反馈给 Claude；`updatedInput` / `updatedPermissions` 只对 `behavior: "allow"` 生效。Claude Code 的 hook 解析路径对 allow 决策最终调用 `handleHookAllow(updatedInput, updatedPermissions)`，不会把 `acceptFeedback` / `message` / `additionalContext` 当成终端 Yes 说明处理。

产品决策：hey-clawd 气泡不提供任何附带说明输入。只在气泡里处理 Allow / Deny / Always allow 的权限决策；如果用户需要告诉 Claude 怎么继续，应回到 Claude Code 终端使用原生 Yes / No 附带说明能力。这样避免只支持 Deny reason、无法支持 Allow feedback 的不对称体验。

终端里的 deny-with-message 会把用户说明写进 rejected `tool_result`。官方 `PermissionDenied` hook 只覆盖 auto mode classifier deny，不覆盖手动拒绝；hey-clawd 通过 `PostToolBatch.tool_calls[*].tool_input` 生成同一 hash，在 `(session_id, tool_name, tool_input_hash)` 唯一命中时关闭残留气泡。

### 4. 响应格式陷阱

**历史 bug**（`367413e`）：最初权限响应直接返回 `{"behavior":"allow"}`，但 Claude Code hook 系统要求 `hookSpecificOutput` 包装。格式不匹配导致 Claude Code 忽略整个响应，用户点了 Allow 但实际无效。

**同一 bug 的连带问题**：suggestion 按钮（Always Allow、Mode 等）只保留了 `label` 用于显示，原始 payload 丢失，即使格式正确也无数据可传。

**当前修法**：`PermissionDecisionResult` 结构体打包 behavior + suggestionPayloads；`BubbleView` 将有效 `addRules` / `addDirectories` 规范化为 session-only `updatedPermissions`；`permissionResponse()` 按 `hookSpecificOutput` 格式组装。

### 5. 首次点击被吞

**历史 bug**（`367413e`）：`BubbleWindow`（NSPanel, nonactivatingPanel）的 NSHostingView `acceptsFirstMouse` 默认返回 false，macOS 将第一次点击消耗在"激活窗口"上。

**修法**：`ClickThroughHostingView` 覆写 `acceptsFirstMouse` 返回 `true`。

### 6. 断连检测竞态

**历史 bug**（`d153dee`）：`ConnectionPermissionTracker` 的 `monitorDisconnect` 注册的 receive 回调可能在 `attach(request)` 之前触发，`pendingPermission` 为 nil 导致断连信号丢失，气泡成孤儿。

**修法**：tracker 加 `isDisconnected` flag，`cancelPendingPermission()` 置 true，`attach()` 检查后立即 cancel。`monitorDisconnect` 改循环接收，非断连数据时递归重新注册 receive。

---

## Hook 注册与自动维护

### 启动注册

`AppDelegate.registerHooksOnLaunch()` → `HookInstaller.register(serverPort:)` 在 HTTPServer 绑定端口后自动运行，确保 hook URL 中的端口号与实际监听端口一致。

### 端口发现

`server-config.js` 的 `postStateToRunningServer` 按以下优先级寻找服务端口：
1. `~/.clawd/runtime.json`（HTTPServer 启动时写入）
2. 扫描 23333–23337 端口范围

### 版本检测

`install.js` 检测 Claude Code 版本（macOS 已知路径 → PATH fallback），对 `PreCompact`（≥ 2.1.76）、`PostCompact`（≥ 2.1.76）、`StopFailure`（≥ 2.1.78）做条件注册。版本检测失败时保守跳过，不注册未确认支持的事件。

---

## 相关提交

| 提交 | 说明 |
|------|------|
| `c2c4be9` | 基础 HTTP 服务器 |
| `e53c681` | 权限气泡 UI |
| `b8c872e` | 多气泡堆叠和生命周期管理 |
| `2242312` | 全局快捷键 Allow/Deny |
| `367413e` | 修复响应格式、suggestion payload、首次点击被吞 |
| `d153dee` | 修复断连检测竞态 |
| `766b25c` | 修复隐藏/解析失败时误 deny |
| `6f6254c` | 启动时自动注册 hook |
