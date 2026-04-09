# Copilot CLI 集成原理

> Clawd 桌宠如何感知 GitHub Copilot CLI 的会话状态。

---

## 架构总览

```
Copilot CLI 进程
  └─ command hook (copilot-hook.js)
       └─ POST /state → HTTPServer → StateMachine → 桌宠动画切换
```

**核心文件**：
- `hooks/copilot-hook.js` — 命令 hook，映射 Copilot 生命周期事件到桌宠状态

---

## 集成方式

单通道：仅 command hook，无 HTTP hook。

### 事件映射

`copilot-hook.js` 的 `EVENT_TO_STATE`：

| Copilot Event | PetState | 说明 |
|--------------|----------|------|
| `sessionStart` | `.idle` | 会话开始 |
| `sessionEnd` | `.sleeping` | 会话结束 |
| `userPromptSubmitted` | `.thinking` | 用户提交 prompt |
| `preToolUse` | `.working` | 工具即将执行 |
| `postToolUse` | `.working` | 工具执行完毕 |
| `errorOccurred` | `.error` | 错误发生 |
| `agentStop` | `.attention` | 回合结束 |
| `subagentStart` | `.juggling` | 子代理启动 |
| `subagentStop` | `.working` | 子代理结束 |
| `preCompact` | `.sweeping` | 上下文压缩 |

**注意**：Copilot CLI 使用独有的事件名（`userPromptSubmitted`、`errorOccurred`、`agentStop`），与 Claude Code / Gemini 均不同。stdin JSON 使用 camelCase 字段名（`sessionId` 而非 `session_id`），hook 脚本做了兼容处理。

### Hook 调用方式

与 Claude Code 类似，通过 `process.argv[2]` 传入事件名，stdin 传入 JSON payload。

---

## 已知局限

### 无自动注册

Copilot CLI 的 hook 脚本（`copilot-hook.js`）**没有对应的安装器**，也不在 `HookInstaller.HookTarget` 枚举中。启动时不会自动注册，菜单中也没有单独的注册入口。

用户需要手动将 hook 配置写入 Copilot CLI 的配置文件。

### 无权限气泡

Copilot CLI 不支持 HTTP hook，权限管理在终端内处理。

### 不支持远程模式

与其他 hook 不同，`copilot-hook.js` 没有 `CLAWD_REMOTE` 环境变量处理，不支持远程开发场景下的状态同步。
