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
- `Sources/App/AppDelegate.swift` — 事件路由和生命周期事件 dismiss

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

气泡有三条关闭路径：

| 路径 | 触发条件 | 代码位置 |
|------|----------|----------|
| **用户决策** | 点击 Allow / Deny / Always allow in this session | `BubbleStack.resolveBubble` → `removeBubble(respondingWith: result)` |
| **手动关闭** | 点击右上角 X，交回 Claude Code 终端侧决策 | `BubbleStack.enqueue` → `removeBubble(respondingWith: .undecided)` |
| **断连检测** | Claude Code 关闭 /permission TCP 连接 | `monitorDisconnect` → `cancelPendingPermission` → `removeBubble(respondingWith: nil)` |
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

### 2. 启发式事件 dismiss 的正确性风险

**背景**：曾考虑通过监听 /state 事件（如检测到同 session 的 `PostToolUse` 或 `working` 状态）来主动 dismiss 气泡。

**为何放弃**：
- /state 事件中没有 tool_id 字段，无法精确关联 "哪个事件对应哪个 permission 请求"
- 同一 session 可能有并行事件（SubagentStop 等），噪声事件会导致**未授权的气泡被错误 dismiss**
- 一旦气泡被误 dismiss，用户丧失 deny 能力，而 /permission 连接仍挂起，Claude Code 干等——比气泡多停留一分钟严重得多

**决策**：移除按 `session_id` 批量生命周期清理。正确性 > 便利性。

### 3. Session always allow

气泡只暴露三个主动作：Allow、Deny、Always allow in this session。`permission_suggestions` 仍会被解析，但不会逐条展示成多个按钮。

- Allow：只批准本次请求，不带 `updatedPermissions`
- Deny：拒绝本次请求
- Always allow in this session：把有效 `addRules` 聚合成一个 `destination: "session"` 的 `updatedPermissions` 条目

对于 `curl | python3` 这类 compound Bash，Claude Code 可能给多个 `addRules` suggestion。hey-clawd 会把它们合并到一个 session-only allow 动作里，不写 `localSettings` / `projectSettings` / `userSettings`。

`setMode`、空 `rules`、非 allow 行为不会进入这个按钮，避免把"本会话总是允许"误变成权限模式切换或无效持久化。

### 4. 响应格式陷阱

**历史 bug**（`367413e`）：最初权限响应直接返回 `{"behavior":"allow"}`，但 Claude Code hook 系统要求 `hookSpecificOutput` 包装。格式不匹配导致 Claude Code 忽略整个响应，用户点了 Allow 但实际无效。

**同一 bug 的连带问题**：suggestion 按钮（Always Allow、Mode 等）只保留了 `label` 用于显示，原始 payload 丢失，即使格式正确也无数据可传。

**当前修法**：`PermissionDecisionResult` 结构体打包 behavior + suggestionPayloads；`BubbleView` 将有效 `addRules` 规范化为 session-only `updatedPermissions`；`permissionResponse()` 按 `hookSpecificOutput` 格式组装。

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
