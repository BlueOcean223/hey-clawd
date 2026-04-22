# Pi 集成原理

> Clawd 桌宠如何感知 Pi（`@mariozechner/pi-coding-agent`）的会话状态。

---

## 架构总览

```
Pi CLI 进程
  └─ Pi extension (~/.pi/agent/extensions/hey-clawd/index.ts + pi-extension-core.js)
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
- `agent_end` 对应一次 user prompt 完整结束。Pi 0.68.0 类型定义写的是 once per user prompt，作为 Stop 锚点稳定。
- `turn_end` 是 per-turn 事件，一次 prompt 可能触发多次，不适合做 Stop。

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
- `source_pid`：通过进程树向上遍历识别出的稳定终端 PID，best-effort
- `editor`：从进程树识别 `code` / `cursor`，best-effort

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
~/.pi/agent/extensions/hey-clawd/pi-extension-core.js
~/.pi/agent/extensions/hey-clawd/.clawd-managed.json
```

installer 会同时复制 `hooks/pi-extension.ts` 和 `hooks/pi-extension-core.js`，分别写成用户目录下的 `index.ts` 和 `pi-extension-core.js`。

### 安装检测

`pi-install.js` 使用双检测策略：

1. `~/.pi/agent/` 是否存在
2. `pi` 命令是否可用

两者都不存在时，installer 静默跳过。

### 自包含 extension 文件

installer 会把 `hooks/pi-extension.ts` 和 `hooks/pi-extension-core.js` 直接复制为用户目录下的 `index.ts` 与 `pi-extension-core.js`，而不是写一个指向 app bundle 内部路径的 wrapper。

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

hey-clawd 当前仅在 `ctx.hasUI=true` 时上报。Pi 官方文档把 RPC 模式也归为有 UI 语义，如果实际 RPC 会话 `ctx.hasUI=true`，会被正常识别上报。

`pi-extension.ts` 在每个事件回调里优先检查 `ctx.hasUI`：

- `ctx.hasUI = true`：允许上报
- `ctx.hasUI = false`：直接跳过，不影响 Pi 正常工作

如果 `ctx` 存在但不含 `hasUI`，当前实现直接视为非 UI，不上报。

只有完全拿不到 `ctx` 的测试或异常路径，才回退到原有判断：

- 没有 `-p` / `--print`
- 没有 `--mode json`
- 没有 `--mode rpc`
- `stdin/stdout` 均为 TTY

只有满足这些条件，才会启用状态上报。

---

## 进程识别

Pi extension 复用了现有 hook 脚本的进程树识别思路，但 `source_pid` / `editor` 都是 best-effort：

- 最多向上遍历 8 层父进程
- 遇到系统边界（`launchd` / `systemd` / `explorer.exe` 等）停止
- 识别常见终端：Terminal、iTerm2、Kitty、WezTerm、Ghostty、Windows Terminal 等
- 识别常见编辑器：VS Code、Cursor

识别成功时，Pi 集成和现有 Gemini / Cursor / Claude Code 一样，能够为：

- Session 菜单的终端跳转
- 编辑器识别
- agent 归属展示

提供基础信息。

---

## 降级行为

Pi extension 是常驻 agent 进程，父进程链在 wrapper、`npx`、内嵌终端这类场景下可能不稳定。

当 `source_pid` 或 `editor` 检测失败时，状态同步仍然照常进行，`/state` 仍会正常 POST。受影响的只有 Session 菜单里这一条记录的“聚焦终端”能力：`[MenuBuilder.swift](/Users/gongshuisanye/code/hey-clawd/Sources/Tray/MenuBuilder.swift:221)` 会因为 `session.sourcePid` 和 `session.editor` 都为空而禁用该项。

这不会影响桌宠动画驱动。宠物状态仍然由 extension 生命周期事件推进。

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
