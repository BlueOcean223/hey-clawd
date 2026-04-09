# Codex CLI 集成原理

> Clawd 桌宠如何感知 OpenAI Codex CLI 的会话状态。

---

## 架构总览

```
Codex CLI 进程
  └─ 写入 ~/.codex/sessions/YYYY/MM/DD/rollout-<uuid>.jsonl
                        │
                        ▼  (kqueue / DispatchSource .write)
               CodexMonitor (actor)
                        │
                        ▼  onStateUpdate callback
               AppDelegate → StateMachine → 桌宠动画切换
```

**核心文件**：
- `Sources/Core/CodexMonitor.swift` — 会话发现 + JSONL 解析 + 事件映射
- `Sources/App/AppDelegate.swift:153` — 启动监控并桥接到状态机

---

## 数据源：rollout JSONL

Codex CLI 每次会话在 `~/.codex/sessions/YYYY/MM/DD/` 下创建 `rollout-<uuid>.jsonl`，每行一个 JSON 对象：

```jsonl
{"type":"session_meta","payload":{"cwd":"/path/to/project",...}}
{"type":"event_msg","payload":{"type":"task_started",...}}
{"type":"response_item","payload":{"type":"function_call",...}}
{"type":"event_msg","payload":{"type":"task_complete",...}}
```

关键字段：
- `type` — 顶层事件类型（`session_meta` / `event_msg` / `response_item`）
- `payload.type` — 子类型，拼接为 `type:payload.type` 作为查找键
- `payload.cwd` — 仅 `session_meta` 携带，记录工作目录

---

## 事件映射

`CodexMonitor.eventMap` 将 JSONL 事件映射到桌宠状态：

| JSONL key | PetState | 说明 |
|-----------|----------|------|
| `session_meta` | `.idle` | 会话初始化 |
| `event_msg:task_started` | `.thinking` | 开始处理任务 |
| `event_msg:user_message` | `.thinking` | 收到用户输入 |
| `event_msg:agent_message` | *(ignored)* | 纯文本回复，不改状态 |
| `response_item:function_call` | `.working` | 执行工具调用 |
| `response_item:custom_tool_call` | `.working` | 自定义工具 |
| `response_item:web_search_call` | `.working` | 网络搜索 |
| `event_msg:task_complete` | `.attention` 或 `.idle` | 任务结束（有过工具调用→attention，否则→idle） |
| `event_msg:context_compacted` | `.sweeping` | 上下文压缩 |
| `event_msg:turn_aborted` | `.idle` | 对话轮中断 |

`task_complete` 的状态取决于 `hadToolUse` 标记：本轮发起过 `function_call` / `custom_tool_call` / `web_search_call` 则落到 `.attention`，否则 `.idle`。

---

## 监控机制

### 文件发现
- 每 1.5 秒扫描最近 3 天的日期目录，寻找新的 `rollout-*.jsonl`
- 仅追踪最近 120 秒内有修改的文件，避免追踪历史会话
- 上限 50 个追踪文件，超过时清理 5 分钟无活动的 stale 文件

### 增量读取
- 使用 `DispatchSource.makeFileSystemObjectSource(.write)` 监听文件写入（macOS kqueue，事件驱动，非轮询）
- 每次触发后 debounce 1.5 秒再读取，避免碎片化读取
- 维护 `offset` 做增量 seek + read，只处理新增内容
- 按换行分割，处理不完整行（`partial` 缓冲，上限 64KB）

### 会话生命周期
- 文件首次被追踪时补读当前全部内容
- 5 分钟无活动 → 标记 stale → 发送 `SessionEnd` → 停止追踪并关闭文件句柄

---

## 已知局限

### 会话菜单不可点击
Codex 会话在菜单中始终灰显（不可跳转到终端窗口）。

**原因**：菜单项启用条件为 `session.sourcePid != nil || session.editor != nil`（`MenuBuilder.swift:187`），而 Codex 监控回调固定传入 `sourcePid: nil, editor: nil`（`AppDelegate.swift:167-169`），因为 JSONL 日志中不包含终端进程 PID。

**对比 Claude Code**：Claude Code 的 hook（`clawd-hook.js`）运行在终端进程内部，可通过 `getStablePid()` 获取宿主终端 PID。Codex 是外部文件监控，无此能力。

**决策**：接受此局限。反查写文件进程（`lsof` / `proc_pidinfo` + 父进程链遍历）复杂度高、涉及系统权限、与桌宠轻量定位不符。Codex 会话作为**状态展示**使用，不提供跳转。

### 权限审核无气泡提示

Codex 等待用户审批工具执行时（终端内显示 "Would you like to run the following command?"），桌宠不会弹出权限气泡。

**原因**：气泡系统依赖**双向 HTTP 协议**。Claude Code 通过 `POST /permission`（`HTTPServer.swift:376`）发送权限请求，HTTP 连接用 `CheckedContinuation` 挂起等待，`BubbleStack` 展示气泡后用户点击 allow/deny，决策通过 HTTP 响应返回给 Claude Code。这是完整的请求-响应闭环。

Codex 的 JSONL 集成是**单向只读**的：
1. JSONL 中没有 "waiting_for_approval" 类型的事件——权限审核完全在终端 UI 内处理，不写入日志
2. 即使能检测到审核状态，也没有回路把用户决策发回给 Codex

**理论替代**：Codex 的 `PreToolUse` hook（`~/.codex/hooks.json`）可以拦截工具调用并返回 approve/deny，理论上可搭建一条"hook → HTTP 通知桌宠 → 用户点击 → hook 返回决策"的通路。但这等于为 Codex 重建一整套权限代理，复杂度与桌宠轻量定位严重不符。

**决策**：接受此局限。Codex 的权限审核由终端 UI 自行处理。

---

## 备选方案调研（2025-04）

| 方案 | 描述 | 结论 |
|------|------|------|
| **JSONL DispatchSource**（当前） | kqueue 监听 rollout 文件写入 | ✅ 最优解：稳定、粒度细、零耦合、原生高效 |
| `codex app-server` WebSocket | JSON-RPC 2.0 协议，VS Code 扩展同款 | ❌ 标记为 experimental，需启动额外进程 |
| `~/.codex/hooks.json` | SessionStart / Stop 等离散事件 | ❌ 粒度不够，无中间状态 |
| lsof 反查 PID | 从文件句柄反推终端进程 | ❌ 复杂、慢、涉及系统权限 |

社区已知的第三方监控项目均采用读 JSONL 方案。
