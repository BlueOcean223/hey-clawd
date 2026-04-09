# Gemini CLI 集成原理

> Clawd 桌宠如何感知 Google Gemini CLI 的会话状态。

---

## 架构总览

```
Gemini CLI 进程
  └─ command hook (gemini-hook.js)
       └─ POST /state → HTTPServer → StateMachine → 桌宠动画切换
```

**核心文件**：
- `hooks/gemini-hook.js` — 命令 hook，映射 Gemini 生命周期事件到桌宠状态
- `hooks/gemini-install.js` — hook 安装器，注册到 `~/.gemini/settings.json`

---

## 集成方式

单通道：仅 command hook，无 HTTP hook。Gemini CLI 的权限审批在终端内处理，不支持外部代理。

### 事件映射

`gemini-hook.js` 的 `HOOK_MAP`：

| Gemini Event | PetState | 映射到的内部 event |
|-------------|----------|-------------------|
| `SessionStart` | `.idle` | `SessionStart` |
| `SessionEnd` | `.sleeping` | `SessionEnd` |
| `BeforeAgent` | `.thinking` | `UserPromptSubmit` |
| `BeforeTool` | `.working` | `PreToolUse` |
| `AfterTool` | `.working` | `PostToolUse` |
| `AfterAgent` | `.attention` | `Stop` |
| `Notification` | `.notification` | `Notification` |
| `PreCompress` | `.sweeping` | `PreCompact` |

### Gating Hook 响应

Gemini CLI 的 gating hooks 需要 stdout JSON 响应：
- `BeforeTool` → `{"decision": "allow"}`（始终放行，状态感知为主）
- `BeforeAgent` → `{}`
- 其他事件 → `{}`

### Hook 注册

`gemini-install.js` 写入 `~/.gemini/settings.json`，格式为扁平 command hook：

```json
{
  "hooks": {
    "SessionStart": [
      { "type": "command", "command": "\"/path/to/node\" \"/path/to/gemini-hook.js\"", "name": "clawd" }
    ]
  }
}
```

安装器检测 `~/.gemini/` 是否存在，未安装 Gemini CLI 时自动跳过。

---

## 已知局限

### 无权限气泡

Gemini CLI 不提供 HTTP hook 类型，工具审批完全在终端内处理。`gemini-hook.js` 对 `BeforeTool` 直接返回 `{"decision": "allow"}`，仅作为状态感知通道。

### 无 PostToolUseFailure 事件

Gemini CLI 的 hook 系统没有工具执行失败事件。工具失败时桌宠不会显示 error 状态，只能等到 `AfterAgent` 回到 attention。

### 无 SubagentStart/Stop 事件

Gemini CLI 不发送子代理事件，多代理协作时桌宠无法显示 juggling 状态。
