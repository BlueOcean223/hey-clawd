# CodeBuddy 集成原理

> Clawd 桌宠如何感知 CodeBuddy 的会话状态并代理权限审批。

---

## 架构总览

```
CodeBuddy 进程
  ├─ command hook (codebuddy-hook.js)
  │    └─ POST /state → HTTPServer → StateMachine → 桌宠动画切换
  │
  └─ HTTP hook (PermissionRequest)
       └─ POST /permission → HTTPServer → BubbleStack → 气泡 UI
                                                  ↓
                                           用户点击 Allow/Deny
                                                  ↓
                                         HTTP 响应返回 CodeBuddy
```

**核心文件**：
- `hooks/codebuddy-hook.js` — 命令 hook，映射生命周期事件到桌宠状态
- `hooks/codebuddy-install.js` — hook 安装器，注册命令 hook + HTTP hook

---

## 集成方式

双通道：command hook（状态感知）+ HTTP hook（权限气泡）。CodeBuddy 使用 Claude Code 兼容的 hook 格式。

### 事件映射

`codebuddy-hook.js` 的 `HOOK_MAP`：

| CodeBuddy Event | PetState | 映射到的内部 event |
|----------------|----------|-------------------|
| `SessionStart` | `.idle` | `SessionStart` |
| `SessionEnd` | `.sleeping` | `SessionEnd` |
| `UserPromptSubmit` | `.thinking` | `UserPromptSubmit` |
| `PreToolUse` | `.working` | `PreToolUse` |
| `PostToolUse` | `.working` | `PostToolUse` |
| `Stop` | `.attention` | `Stop` |
| `Notification` | `.notification` | `Notification` |
| `PreCompact` | `.sweeping` | `PreCompact` |

### 权限气泡

CodeBuddy 支持 HTTP hook（`PermissionRequest`），权限气泡链路与 Claude Code 完全一致。安装器注册格式为 Claude Code 兼容的嵌套结构：

```json
{
  "PermissionRequest": [{
    "matcher": "",
    "hooks": [{ "type": "http", "url": "http://127.0.0.1:23333/permission", "timeout": 600 }]
  }]
}
```

### Gating Hook 响应

- `PreToolUse` → `{"decision": "allow"}`（始终放行）
- 其他事件 → `{}`

### Hook 注册格式

CodeBuddy 使用 Claude Code 兼容的嵌套格式（`{ matcher, hooks: [{ type, command }] }`），安装器同时兼容扁平格式用于迁移：

```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{ "type": "command", "command": "\"/path/to/node\" \"/path/to/codebuddy-hook.js\"" }]
    }]
  }
}
```

配置文件路径：`~/.codebuddy/settings.json`。安装器检测目录是否存在，未安装时自动跳过。

---

## 已知局限

### 事件覆盖不完整

CodeBuddy 注册的事件数量（8 个）少于 Claude Code（12+ 个），缺少：
- `PostToolUseFailure` — 工具失败不触发 error 状态
- `StopFailure` — 停止失败不触发 error 状态
- `SubagentStart` / `SubagentStop` — 不支持 juggling 状态
- `PostCompact` — 压缩完成不触发 attention 状态

### 权限气泡与 Claude Code 共享相同局限

终端批准后气泡残留、PermissionDenied 事件未闭环等问题同样存在，详见 [Claude Code 集成文档](claude-code-integration.md) 的局限性章节。
