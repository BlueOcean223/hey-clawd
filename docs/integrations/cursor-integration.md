# Cursor 集成原理

> Clawd 桌宠如何感知 Cursor Agent 的会话状态。

---

## 架构总览

```
Cursor Agent 进程
  └─ command hook (cursor-hook.js)
       └─ POST /state → HTTPServer → StateMachine → 桌宠动画切换
```

**核心文件**：
- `hooks/cursor-hook.js` — 命令 hook，映射 Cursor 生命周期事件到桌宠状态
- `hooks/cursor-install.js` — hook 安装器，注册到 `~/.cursor/hooks.json`

---

## 集成方式

单通道：仅 command hook，无 HTTP hook。Cursor 的权限管理在编辑器 UI 内处理。

### 事件映射

`cursor-hook.js` 的 `HOOK_TO_STATE`：

| Cursor Event | PetState | 映射到的内部 event |
|-------------|----------|-------------------|
| `sessionStart` | `.idle` | `SessionStart` |
| `sessionEnd` | `.sleeping` | `SessionEnd` |
| `beforeSubmitPrompt` | `.thinking` | `UserPromptSubmit` |
| `preToolUse` | `.working` | `PreToolUse` |
| `postToolUse` | `.working` | `PostToolUse` |
| `postToolUseFailure` | `.error` | `PostToolUseFailure` |
| `subagentStart` | `.juggling` | `SubagentStart` |
| `subagentStop` | `.working` | `SubagentStop` |
| `preCompact` | `.sweeping` | `PreCompact` |
| `afterAgentThought` | `.thinking` | `AfterAgentThought` |
| `stop` (status=error) | `.error` | `StopFailure` |
| `stop` (其他) | `.attention` | `Stop` |

**注意**：Cursor 使用 camelCase 事件名（`sessionStart`），与 Claude Code 的 PascalCase（`SessionStart`）不同。`stop` 事件通过 `payload.status` 区分正常结束和错误。

### 工具级 SVG 提示

Cursor hook 独有功能——根据工具类型发送 `display_svg` 字段，让桌宠展示更精确的动画：

| tool_name | display_svg |
|-----------|-------------|
| `Shell`、`MCP:*` | `clawd-working-building.svg` |
| `Task` | `clawd-working-juggling.svg` |
| `Write`、`Delete` | `clawd-working-typing.svg` |
| `Read`、`Grep` | `clawd-idle-reading.svg` |

### Gating Hook 响应

- `beforeSubmitPrompt` → `{"continue": true}`（不覆盖 Cursor 的权限系统）
- 其他事件 → `{}`

### 会话 ID

Cursor 的 payload 使用 `conversation_id` 字段（优先），回退到 `session_id`。工作目录从 `cwd` 或 `workspace_roots[0]` 获取。

### Hook 注册

`cursor-install.js` 写入 `~/.cursor/hooks.json`，格式为扁平 command hook：

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "command": "\"/path/to/node\" \"/path/to/cursor-hook.js\"" }
    ]
  }
}
```

安装器检测 `~/.cursor/` 是否存在，未安装 Cursor 时自动跳过。

---

## 已知局限

### 无权限气泡

Cursor 不提供 HTTP hook 类型，权限管理完全在编辑器 UI 内处理。

### 编辑器检测默认值

与其他 hook 不同，Cursor hook 在 `editor` 字段缺省时直接填 `"cursor"`（`cursor-hook.js:169`），因为 Cursor Agent 必然在 Cursor 编辑器内运行。
