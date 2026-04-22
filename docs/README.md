# docs

hey-clawd 的设计与集成文档。面向想理解渲染管线或为新 AI 工具加集成的贡献者。

项目概览请看仓库根目录的 `README.md` 与 `CLAUDE.md`；SVG 动画/像素网格规范见 `svg-animation-spec.md`。

---

## 目录结构

```
docs/
├── README.md              ← 本文件
├── rendering-system.md    ← 渲染管线深入讲解（WKWebView → Core Animation 重写）
├── svg-animation-spec.md  ← SVG 动画规范、像素网格、配色与动画分层约定
├── svg-catalog.md         ← 所有 clawd-*.svg 动画的出场方式与状态映射
└── integrations/          ← 各 AI 编码工具的集成原理
    ├── platform-comparison.md        ← 七种工具的能力/事件覆盖度对比矩阵
    ├── claude-code-integration.md    ← Claude Code（含权限气泡完整链路）
    ├── codebuddy-integration.md      ← CodeBuddy（含权限气泡）
    ├── codex-integration.md          ← Codex CLI（JSONL 日志监控，唯一非 hook 方案）
    ├── cursor-integration.md         ← Cursor Agent
    ├── gemini-cli-integration.md     ← Gemini CLI
    ├── pi-integration.md             ← Pi（extension 单向状态同步）
    └── copilot-cli-integration.md    ← GitHub Copilot CLI
```

---

## 按主题索引

### 我想理解桌宠是怎么画出来的
- `rendering-system.md` — 从 WKWebView 到 Core Animation 的重写动机、架构、性能数据
- `svg-animation-spec.md` — SVG 动画规范、像素网格、配色、分层与质量检查清单
- `svg-catalog.md` — 每个 `PetState` 对应哪个 SVG、触发条件是什么

### 我想加一个新 AI 工具的集成
1. 先读 `integrations/platform-comparison.md` 对齐现有方案的能力边界
2. 选一个最接近的范式作为模板：
   - **hook 双向（含权限）** → `claude-code-integration.md` / `codebuddy-integration.md`
   - **hook 单向（仅状态）** → `cursor-integration.md` / `gemini-cli-integration.md` / `copilot-cli-integration.md`
   - **extension 单向（仅状态）** → `pi-integration.md`
   - **日志监控（无 hook 能力）** → `codex-integration.md`
3. 实现时同步更新 `hooks/`、`agents/`、`docs/integrations/` 三处，避免事件映射漂移

### 我想排查某个工具的状态不刷新
- 先对照 `platform-comparison.md` 的事件覆盖度表确认该事件是否被支持
- 再去对应的 `*-integration.md` 查链路细节

---

## 维护约定

- 新加集成文档命名为 `integrations/<tool>-integration.md`，并在 `platform-comparison.md` 的矩阵里加一列。
- 修改 hook 事件映射时，同步检查对应 `*-integration.md` 中的事件表，防止文档与代码脱节。
- SVG 动画规范统一维护在 `svg-animation-spec.md`；渲染实现原理与架构说明维护在 `rendering-system.md`。
