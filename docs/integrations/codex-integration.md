# Codex CLI 集成原理

> Clawd 桌宠如何通过 Codex native hooks 感知会话状态，并在实验开关打开时接管单次权限审批。

---

## 架构总览

```
Codex CLI
  └─ native command hook (~/.codex/hooks.json)
       └─ hooks/codex-hook.js
            ├─ 状态事件 → POST /state → HTTPServer → StateMachine → 桌宠动画切换
            └─ PermissionRequest（实验开关）→ POST /permission → BubbleStack → 气泡 UI
                                                             ↓
                                                      Allow / Deny
                                                             ↓
                                         Codex-safe hook stdout response
```

**核心文件**：
- `hooks/codex-install.js` — 安装/卸载用户级 Codex hooks
- `hooks/codex-hook.js` — 读取 Codex stdin JSON，映射状态并处理 `PermissionRequest`
- `Sources/Core/HookInstaller.swift` — 将 Codex 纳入自动注册/手动注册/卸载
- `Sources/Core/HTTPServer.swift` — 根据 `agent_id: "codex"` 返回 Codex-safe 权限响应
- `Sources/App/AppDelegate.swift` — 权限气泡入口和终端侧审批后的残留气泡清理

---

## 安装与配置边界

`codex-install.js` 只维护用户级 `~/.codex/hooks.json`：

- `~/.codex/` 不存在时直接跳过，不主动创建 Codex 配置目录
- 不读取、不修改 `~/.codex/config.toml`
- append-only / idempotent merge，不覆盖用户已有 hooks
- 默认只注册状态同步 hook，并清理旧版本遗留的 Clawd `PermissionRequest` hook
- 只有 `Hooks → 实验 → Codex 权限审核` 打开时，才额外注册 `PermissionRequest` hook
- 以 command 中包含 `codex-hook.js` 作为 hey-clawd 条目标记
- `--uninstall` 只移除 hey-clawd 写入的 `codex-hook.js` 条目，保留用户其他 hooks

如果用户在 Codex 配置中禁用了 `features.hooks`，Codex hook engine 不会执行这些 hooks。此时 hey-clawd 的 Codex 集成静默失效，Codex 自身行为不受影响。

Codex 首次发现新的 command hooks 时，可能会提示 `hooks need review before they can run`。用户需要在 Codex 内执行 `/hooks`，检查并 trust/enable hey-clawd 写入的 `codex-hook.js` 命令；完成 review 之前，`~/.codex/hooks.json` 中的条目会保留但不会执行。这是 Codex 自身的 hook 信任门槛，hey-clawd installer 不能也不应该绕过。

注册事件：

| Codex hook event | hey-clawd state | 说明 |
|---|---|---|
| `SessionStart` | `idle` | 会话开始 |
| `UserPromptSubmit` | `thinking` | 用户提交 prompt |
| `PreToolUse` | `working` | 工具调用前 |
| `PermissionRequest` | `notification` / 权限气泡 | 实验开关打开时才注册；仅非 bypass / dontAsk 时转发 `/permission` |
| `PostToolUse` | `working` | 工具调用后；同时用于唯一匹配关闭残留气泡 |
| `Stop` | `attention` | 回合结束 |
| `PreCompact` | `sweeping` | 上下文压缩开始 |
| `PostCompact` | `idle` | 上下文压缩完成 |

---

## 状态上报

`codex-hook.js` 从 stdin 读取 Codex hook JSON，只依赖 `hook_event_name`，不从 argv 推断事件。所有状态事件都会：

- 将 `session_id` 规范化为 `codex:<session_id>`
- 固定上报 `agent_id: "codex"`
- 保留 `cwd`、`turn_id`、`tool_name`、`tool_use_id`
- 使用 `hooks/lib/match-key.js` 为 `tool_input` 计算 `tool_input_hash`
- 以 100ms 超时 POST `/state`
- app 不可达、超时、未知事件、malformed stdin 时输出 `{}` 并 fail-open

状态 body 示例：

```json
{
  "state": "working",
  "session_id": "codex:session-123",
  "event": "PreToolUse",
  "agent_id": "codex",
  "cwd": "/repo",
  "turn_id": "turn-1",
  "tool_name": "shell",
  "tool_use_id": "call-1",
  "tool_input_hash": "..."
}
```

---

## 权限气泡（实验开关）

Codex `PermissionRequest` 走 command hook stdout 决策，而不是 Claude Code 的 HTTP hook 直连。因此 hey-clawd 先由 `codex-hook.js` POST `/permission`，再把 HTTPServer 返回的 Codex-safe JSON 原样写回 stdout。

这个功能默认关闭。开启路径：

```text
Hooks → 实验 → Codex 权限审核
```

开启前会弹窗提醒用户：启用后 Clawd 会接管 Codex 的单次权限审批，Codex 终端会等待气泡 Allow/Deny。关闭该开关时，只清理 Codex `PermissionRequest` hook，保留其它状态同步 hooks。

行为边界：

- `permission_mode` 为 `bypassPermissions` 或 `dontAsk` 时不弹气泡，直接输出 `{}`
- 只支持单次 **Allow** / **Deny**
- 不支持 **Always allow**、`updatedPermissions`、`updatedInput` 或 `interrupt`
- DND / hide bubbles / 手动关闭 / 超时 / app 不可达 / undecided 都返回 `{}`，让 Codex 原生审批流继续
- `/permission` 等待约 305s；Codex hook 注册 timeout 为 600s
- 终端侧完成审批后，后续 `PostToolUse` 会用 `(session, tool_name, tool_input_hash)` 唯一匹配并关闭残留气泡；多匹配或缺字段时跳过

Codex allow：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

Codex deny：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Denied by user."
    }
  }
}
```

Codex undecided / fail-open：

```json
{}
```

---

## 已知局限

### 终端跳转

当前 Codex hook payload 不提供稳定的宿主终端 PID，hey-clawd 也不会从日志或系统文件句柄反查进程。因此 Codex 会话用于状态展示和权限辅助，不提供菜单里的终端跳转。

### 权限能力少于 Claude Code

Codex 当前 schema 不接受 `updatedPermissions`，所以 hey-clawd 不能提供 “Always allow in this session”。需要长期放行某些工具时，应在 Codex 自身配置中处理。

---

## 历史说明

hey-clawd 曾通过 `~/.codex/sessions/**/*.jsonl` 被动 monitor Codex 状态；该方案在 Codex native hooks stable 后废弃并从代码中移除。该历史说明仅用于解释旧版本行为，不代表当前支持路径。
