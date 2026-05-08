# 各平台集成对比

> Clawd 桌宠支持的所有 AI 编码工具的集成能力对比。

---

## 能力矩阵

| 能力 | Claude Code | CodeBuddy | Gemini CLI | Cursor | Copilot CLI | Codex CLI | Pi |
|------|:-----------:|:---------:|:----------:|:------:|:-----------:|:---------:|:--:|
| **集成方式** | hook | hook | hook | hook | hook | native hook | extension |
| **数据方向** | 双向 | 双向 | 单向 | 单向 | 单向 | 双向 | 单向 |
| **权限气泡** | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ 单次 Allow/Deny | ❌ |
| **终端跳转** | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **编辑器检测** | ✅ | ✅ | ✅ | ✅ (默认 cursor) | ✅ | ❌ | ✅ |
| **远程模式** | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **自动注册** | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| **headless 检测** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| **工具级 SVG 提示** | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ |

---

## 事件覆盖度

| 事件类别 | Claude Code | CodeBuddy | Gemini CLI | Cursor | Copilot CLI | Codex CLI | Pi |
|---------|:-----------:|:---------:|:----------:|:------:|:-----------:|:---------:|:--:|
| 会话开始/结束 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 用户提交 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 工具执行（前/后） | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 工具执行失败 | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ |
| 回合结束 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 停止失败 | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ |
| 子代理启停 | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ |
| 上下文压缩 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 压缩完成 | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| 权限请求 | ✅ (HTTP) | ✅ (HTTP) | ❌ | ❌ | ❌ | ✅ (command) | ❌ |
| 通知 | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 工作树创建 | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 代理思考 | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ |

---

## 配置文件与格式

| 平台 | 配置文件 | Hook / Extension 格式 |
|------|---------|-----------------------|
| Claude Code | `~/.claude/settings.json` | 嵌套 `{ matcher, hooks: [{ type, command }] }` + HTTP hook |
| CodeBuddy | `~/.codebuddy/settings.json` | 同 Claude Code（嵌套格式） |
| Gemini CLI | `~/.gemini/settings.json` | 嵌套 `{ hooks: [{ type: "command", command, name }] }` |
| Cursor | `~/.cursor/hooks.json` | 扁平 `{ command }` |
| Copilot CLI | 手动配置 | 扁平（通过 argv 传事件名） |
| Codex CLI | `~/.codex/hooks.json` | 嵌套 command hooks，stdin JSON，stdout decision |
| Pi | `~/.pi/agent/extensions/hey-clawd/` | 自包含 `index.ts` + marker（`.clawd-managed.json`） |

---

## 事件名约定差异

各平台使用不同的事件名风格，hook 脚本内部统一映射到 Clawd 内部事件名（PascalCase）：

| 语义 | Claude Code | CodeBuddy | Gemini CLI | Cursor | Copilot CLI | Codex CLI | Pi |
|------|-------------|-----------|------------|--------|-------------|-----------|----|
| 会话开始 | `SessionStart` | `SessionStart` | `SessionStart` | `sessionStart` | `sessionStart` | `SessionStart` | `session_start` |
| 用户提交 | `UserPromptSubmit` | `UserPromptSubmit` | `BeforeAgent` | `beforeSubmitPrompt` | `userPromptSubmitted` | `UserPromptSubmit` | `before_agent_start` |
| 工具执行前 | `PreToolUse` | `PreToolUse` | `BeforeTool` | `preToolUse` | `preToolUse` | `PreToolUse` | `tool_call` |
| 工具执行后 | `PostToolUse` | `PostToolUse` | `AfterTool` | `postToolUse` | `postToolUse` | `PostToolUse` | `tool_result` |
| 回合结束 | `Stop` | `Stop` | `AfterAgent` | `stop` | `agentStop` | `Stop` | `agent_end` |
| 错误 | `PostToolUseFailure` | — | — | `postToolUseFailure` | `errorOccurred` | — | `tool_result(isError=true)` |

---

## 权限气泡支持详情

Claude Code、CodeBuddy 和 Codex CLI 支持权限气泡。Claude Code / CodeBuddy 走 HTTP hook；Codex 由 `codex-hook.js` 在 `PermissionRequest` command hook 中 POST `/permission`，再把 Codex-safe 决策写回 stdout。

```
POST /permission → HTTPServer → BubbleStack → 气泡 UI → HTTP 响应 / Codex stdout
```

**不支持的原因各不相同**：

| 平台 | 为什么没有权限气泡 |
|------|-------------------|
| Gemini CLI | 无 HTTP hook 类型，工具审批在终端内处理 |
| Cursor | 权限管理在编辑器 UI 内处理，hook 系统无 HTTP 类型 |
| Copilot CLI | hook 系统无 HTTP 类型 |
| Pi | 本次集成明确只做 extension 单向状态同步，不代理 Pi 的工具审批体验 |

---

## 兜底策略

### 全平台共通

- **进程树遍历**：多数 CLI hook 脚本实现了 `getStablePid()`，向上遍历 8 层找到宿主终端 PID，覆盖 macOS / Linux / Windows 的主流终端；Codex 当前 hook payload 不提供稳定终端 PID，暂不支持终端跳转
- **stdin 超时**：400ms 内 stdin 未结束则以默认值发送，防止 hook 进程挂死
- **端口发现**：`server-config.js` 先查 `~/.clawd/runtime.json`，再扫描 23333–23337 端口范围
- **安装检测**：每个安装器检测对应工具目录（`~/.claude/`、`~/.gemini/`、`~/.codex/`、`~/.pi/agent/` 等），未安装时静默跳过
- **路径自愈**：安装器检测到已注册 hook 的 node/script 路径过期时自动更新；Pi 采用自包含 extension，不依赖 bundle 内脚本路径

### 权限气泡（Claude Code / CodeBuddy / Codex）

- **Passthrough 自动批准**：TaskCreate/TaskUpdate 等无风险工具直接放行
- **断连检测**：TCP 连接关闭时自动撤掉气泡（`monitorDisconnect` 循环 receive），覆盖终端 Deny 路径
- **工具完成唯一匹配自动关闭**（Claude Code / Codex）：终端 Allow 后客户端不一定关闭待决气泡；工具完成后会发 `PostToolUse`。Claude Code 终端 deny-with-message 可由 `PostToolBatch` 覆盖。hook 默认携带 `tool_input_hash` 元数据，hey-clawd 在 `(session, tool, hash)` 唯一锁定时关闭气泡（多匹配跳过保护）
- **5 分钟超时兜底**：`PendingPermissionRequest` 入栈后 5 分钟仍未决策时自动 `.undecided`，覆盖 hook 失败 / 进程僵死等边缘场景
- **明确关闭路径**：用户决策、手动关闭、HTTP 断连、PostToolUse / PostToolUseFailure / PostToolBatch 唯一匹配、5 分钟超时；不按 `session_id` 批量清理
- **Session allow**（Claude Code / CodeBuddy）：多个 `addRules` / `addDirectories` suggestion 聚合为一个 `Always allow in this session` 按钮，只写 `destination: "session"`。Codex 不支持 `updatedPermissions`，因此不显示 Always allow。
- **附加信息边界**：Claude Code 终端 Yes / No 都支持说明；HTTP `PermissionRequest` hook 只提供 deny-only message，不能复刻终端 Yes feedback。为避免不对称体验，气泡不提供任何说明输入，需要说明时回终端处理
- **终端 deny-with-message 消泡**：手动拒绝并附带说明不会触发 `PermissionDenied`；Claude Code 2.1.119 起注册 `PostToolBatch`，用批次里的 tool hash 做唯一匹配消泡
- **DND 模式**：勿扰模式下 Claude Code / CodeBuddy 返回 `undecided`，Codex 返回 `{}`，让客户端回退到原生审批
- **手动关闭按钮**：气泡右上角 × 按钮，作为协议无法证明场景的最终兜底

### Codex CLI 特有

- **native hooks**：`codex-install.js` 只写用户级 `~/.codex/hooks.json`，不创建 `~/.codex/`，不修改 `~/.codex/config.toml`
- **hook review 门槛**：Codex 首次发现新的 command hooks 时可能要求用户在 `/hooks` 中 review/trust；完成前 hooks 已注册但不会执行
- **fail-open**：状态上报 100ms 超时；权限路径在 app 不可达、超时、undecided、DND、hide bubbles 时返回 `{}`，Codex 原生审批流继续
- **权限边界**：只支持单次 Allow / Deny；不支持 Always allow、`updatedPermissions`、`updatedInput` 或 `interrupt`
- **bypass 模式**：`permission_mode` 为 `bypassPermissions` 或 `dontAsk` 时不弹权限气泡，普通状态事件仍会上报
- **历史说明**：旧版曾通过 `~/.codex/sessions/**/*.jsonl` 被动监控 Codex 状态；该 JSONL monitor 已在 Codex native hooks stable 后从代码中移除，不是当前支持路径

### Gemini CLI 特有

- **启动时加载 hooks**：`~/.gemini/settings.json` 注册嵌套 command hook；已运行的 Gemini CLI 不会热加载更新后的 settings，需要重启 Gemini 会话
- **Node/shebang 进程识别**：Gemini CLI 可能以 Node 进程运行；hook 会检查父进程 command line，补齐 `agent_pid`，让 CLI 退出后菜单能及时清理
