# 各平台集成对比

> Clawd 桌宠支持的所有 AI 编码工具的集成能力对比。

---

## 能力矩阵

| 能力 | Claude Code | CodeBuddy | Gemini CLI | Cursor | Copilot CLI | Codex CLI |
|------|:-----------:|:---------:|:----------:|:------:|:-----------:|:---------:|
| **集成方式** | hook | hook | hook | hook | hook | JSONL 监控 |
| **数据方向** | 双向 | 双向 | 单向 | 单向 | 单向 | 单向只读 |
| **权限气泡** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **终端跳转** | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **编辑器检测** | ✅ | ✅ | ✅ | ✅ (默认 cursor) | ✅ | ❌ |
| **远程模式** | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| **自动注册** | ✅ | ✅ | ✅ | ✅ | ❌ | N/A |
| **headless 检测** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **工具级 SVG 提示** | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |

---

## 事件覆盖度

| 事件类别 | Claude Code | CodeBuddy | Gemini CLI | Cursor | Copilot CLI | Codex CLI |
|---------|:-----------:|:---------:|:----------:|:------:|:-----------:|:---------:|
| 会话开始/结束 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 用户提交 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 工具执行（前/后） | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 工具执行失败 | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ |
| 回合结束 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 停止失败 | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ |
| 子代理启停 | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ |
| 上下文压缩 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 压缩完成 | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 权限请求 | ✅ (HTTP) | ✅ (HTTP) | ❌ | ❌ | ❌ | ❌ |
| 通知 | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 工作树创建 | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 代理思考 | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |

---

## 配置文件与格式

| 平台 | 配置文件 | Hook 格式 |
|------|---------|-----------|
| Claude Code | `~/.claude/settings.json` | 嵌套 `{ matcher, hooks: [{ type, command }] }` + HTTP hook |
| CodeBuddy | `~/.codebuddy/settings.json` | 同 Claude Code（嵌套格式） |
| Gemini CLI | `~/.gemini/settings.json` | 扁平 `{ type: "command", command, name }` |
| Cursor | `~/.cursor/hooks.json` | 扁平 `{ command }` |
| Copilot CLI | 手动配置 | 扁平（通过 argv 传事件名） |
| Codex CLI | N/A | 无 hook，被动读取 `~/.codex/sessions/` JSONL |

---

## 事件名约定差异

各平台使用不同的事件名风格，hook 脚本内部统一映射到 Clawd 内部事件名（PascalCase）：

| 语义 | Claude Code | CodeBuddy | Gemini CLI | Cursor | Copilot CLI |
|------|-------------|-----------|------------|--------|-------------|
| 会话开始 | `SessionStart` | `SessionStart` | `SessionStart` | `sessionStart` | `sessionStart` |
| 用户提交 | `UserPromptSubmit` | `UserPromptSubmit` | `BeforeAgent` | `beforeSubmitPrompt` | `userPromptSubmitted` |
| 工具执行前 | `PreToolUse` | `PreToolUse` | `BeforeTool` | `preToolUse` | `preToolUse` |
| 工具执行后 | `PostToolUse` | `PostToolUse` | `AfterTool` | `postToolUse` | `postToolUse` |
| 回合结束 | `Stop` | `Stop` | `AfterAgent` | `stop` | `agentStop` |
| 错误 | `PostToolUseFailure` | — | — | `postToolUseFailure` | `errorOccurred` |

---

## 权限气泡支持详情

仅 Claude Code 和 CodeBuddy 支持权限气泡。两者走完全相同的链路：

```
POST /permission → HTTPServer → BubbleStack → 气泡 UI → HTTP 响应
```

**不支持的原因各不相同**：

| 平台 | 为什么没有权限气泡 |
|------|-------------------|
| Gemini CLI | 无 HTTP hook 类型，工具审批在终端内处理 |
| Cursor | 权限管理在编辑器 UI 内处理，hook 系统无 HTTP 类型 |
| Copilot CLI | hook 系统无 HTTP 类型 |
| Codex CLI | 单向只读 JSONL 监控，无回路；JSONL 不记录审批事件 |

---

## 兜底策略

### 全平台共通

- **进程树遍历**：所有 hook 脚本都实现了 `getStablePid()`，向上遍历 8 层找到宿主终端 PID，覆盖 macOS / Linux / Windows 的主流终端
- **stdin 超时**：400ms 内 stdin 未结束则以默认值发送，防止 hook 进程挂死
- **端口发现**：`server-config.js` 先查 `~/.clawd/runtime.json`，再扫描 23333–23337 端口范围
- **安装检测**：每个安装器检测对应工具目录（`~/.claude/`、`~/.gemini/` 等），未安装时静默跳过
- **路径自愈**：安装器检测到已注册 hook 的 node/script 路径过期时自动更新

### 权限气泡（Claude Code / CodeBuddy）

- **Passthrough 自动批准**：TaskCreate/TaskUpdate 等无风险工具直接放行
- **断连检测**：TCP 连接关闭时自动撤掉气泡（`monitorDisconnect` 循环 receive）
- **生命周期事件清理**：PostToolUse/Stop/SessionEnd 等事件触发时按 session_id 清理残留气泡
- **DND 模式**：勿扰模式下所有权限请求直接 deny，不弹气泡
- **手动关闭按钮**：气泡右上角 × 按钮，覆盖终端批准后连接不断开导致气泡残留的场景（计划中）

### Codex CLI 特有

- **kqueue 事件驱动**：`DispatchSource.makeFileSystemObjectSource(.write)`，不轮询
- **Debounce 1.5s**：避免碎片化读取
- **Stale 文件清理**：5 分钟无活动的会话自动发送 SessionEnd
