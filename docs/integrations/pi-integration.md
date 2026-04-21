# Pi 集成原理

> Clawd 桌宠如何感知 Pi（`@mariozechner/pi-coding-agent`）的会话状态。

---

## 架构总览

```
Pi CLI 进程
  └─ Pi extension (~/.pi/agent/extensions/hey-clawd/index.ts)
       └─ POST /state → HTTPServer → StateMachine → 桌宠动画切换
```

**核心文件**：
- `hooks/pi-extension.ts` — Pi extension，监听 Pi 生命周期事件并上报到 hey-clawd `/state`
- `hooks/pi-install.js` — installer，负责安装/卸载 hey-clawd 托管的 Pi extension
- `agents/pi.js` — Pi agent 元数据，供运行时 registry / session UI 使用

---

## 集成方式

单通道：**extension → /state**。Pi 集成不是传统 hook 配置文件模式，而是通过 Pi 的 extension 机制把状态主动推送给 hey-clawd。

### 为什么不用 JSONL 监控

虽然 Pi 的 session 也存为 JSONL，但 hey-clawd 没有采用类似 Codex CLI 的日志监控方案，原因是：

1. session JSONL 是存储格式，不是实时事件总线
2. 很难稳定还原 `tool_call` 之前的时机
3. Pi 官方已提供足够完整的 extension 生命周期事件

因此，Pi 集成直接监听 extension 事件，而不是轮询 `~/.pi/agent/sessions/`。

---

## 事件映射

`pi-extension.ts` 的状态映射：

| Pi Extension Event | PetState | 映射到的内部 event |
|--------------------|----------|-------------------|
| `session_start` | `.idle` | `SessionStart` |
| `before_agent_start` | `.thinking` | `UserPromptSubmit` |
| `tool_call` | `.working` | `PreToolUse` |
| `tool_result` | `.working` | `PostToolUse` |
| `tool_result` (`isError=true`) | `.working` | `PostToolUseFailure` |
| `agent_end` | `.attention` | `Stop` |
| `session_before_compact` | `.sweeping` | `PreCompact` |
| `session_compact` | `.attention` | `PostCompact` |
| `session_shutdown` | `.sleeping` | `SessionEnd` |

### 说明

- `tool_result.isError = true` 仍映射到 `PostToolUseFailure`，但状态保持 `working`，与 Cursor / Claude Code 当前的“工具失败不等于任务失败”策略一致。
- 本次实现**没有额外映射 Pi 的 turn_start / turn_end**，因为对桌宠来说 `before_agent_start`、`tool_call`、`agent_end` 已足够覆盖主要动画状态。

---

## payload 格式

Pi extension 向 hey-clawd `/state` 发送的 JSON 与现有 hooks 风格保持一致：

```json
{
  "state": "working",
  "session_id": "pi:<session-id>",
  "event": "PreToolUse",
  "cwd": "/path/to/project",
  "agent_id": "pi",
  "agent_pid": 23456,
  "source_pid": 12345,
  "editor": "cursor"
}
```

字段说明：

- `session_id`：使用 `pi:<uuid>` 前缀，避免和其他 agent 的 session 形态冲突
- `agent_id`：固定为 `pi`
- `agent_pid`：Pi 进程 PID（`process.pid`）
- `source_pid`：通过进程树向上遍历识别出的稳定终端 PID
- `editor`：从进程树识别 `code` / `cursor`

---

## 安装与卸载

### 安装位置

Pi extension 全局安装到：

```text
~/.pi/agent/extensions/hey-clawd/
```

主要产物：

```text
~/.pi/agent/extensions/hey-clawd/index.ts
~/.pi/agent/extensions/hey-clawd/.clawd-managed.json
```

### 安装检测

`pi-install.js` 使用双检测策略：

1. `~/.pi/agent/` 是否存在
2. `pi` 命令是否可用

两者都不存在时，installer 静默跳过。

### 自包含 extension

installer 会把 `hooks/pi-extension.ts` 的内容直接复制为用户目录下的 `index.ts`，而不是写一个指向 app bundle 内部路径的 wrapper。

这样做的好处：

- 不依赖 app bundle / DerivedData 路径
- 调试版与正式版都不容易出现“路径失效”问题
- 卸载语义简单明确

### 托管卸载

为了避免误删用户自建目录，卸载只会删除带 marker 的目录：

```text
.clawd-managed.json
```

marker 至少包含：

- `app = "hey-clawd"`
- `integration = "pi"`

如果目录存在但 marker 不匹配，则视为**非 hey-clawd 托管目录**，跳过清理。

---

## 交互模式边界

当前实现 **仅正式支持交互式 Pi**。

`pi-extension.ts` 会在加载时检查：

- 没有 `-p` / `--print`
- 没有 `--mode json`
- 没有 `--mode rpc`
- `stdin/stdout` 均为 TTY

只有满足这些条件，才会启用状态上报。

### 为什么只支持交互式 Pi

因为 hey-clawd 当前定位是“本地前台 coding session 的状态宠物”，而不是追踪所有 headless / 嵌入式 agent 运行场景。

因此以下模式暂不承诺支持：

- `pi -p`
- `pi --mode json`
- `pi --mode rpc`

这些模式下 extension 不应打断 Pi 正常工作，也不保证驱动桌宠状态。

---

## 进程识别

Pi extension 复用了现有 hook 脚本的进程树识别思路：

- 最多向上遍历 8 层父进程
- 遇到系统边界（`launchd` / `systemd` / `explorer.exe` 等）停止
- 识别常见终端：Terminal、iTerm2、Kitty、WezTerm、Ghostty、Windows Terminal 等
- 识别常见编辑器：VS Code、Cursor

这让 Pi 集成和现有 Gemini / Cursor / Claude Code 一样，能够为：

- Session 菜单的终端跳转
- 编辑器识别
- agent 归属展示

提供基础信息。

---

## 已知局限

### 无权限气泡

Pi 集成**明确不做** hey-clawd 权限气泡。

原因不是技术上做不到，而是产品边界有意保持克制：

- Pi 官方并没有内建权限弹窗哲学
- hey-clawd 不应替 Pi 强行引入一套外部审批 UX
- 当前只把 Pi 当作“状态源”，而不是“工具决策代理”

### 无 subagent 状态

Pi 虽然可通过扩展做更复杂工作流，但 hey-clawd 当前对 Pi 的集成不承诺 subagent 语义，因此不会显示 `.juggling` 等子代理状态。

### 无远程模式支持

当前没有对齐 `CLAWD_REMOTE` 或类似 host 前缀逻辑，远程开发场景不在本次支持范围内。

### 图标不是前置条件

如果仓库中未来补上 `Resources/icons/agents/pi.png`，菜单 / sessions 可显示 Pi 图标；当前没有图标文件时，会自动回退到默认 agent 图标，不影响功能。
