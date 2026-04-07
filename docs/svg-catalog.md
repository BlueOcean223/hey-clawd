# SVG Animation Catalog & Appearance Plan

> 所有 Clawd SVG 动画的出场方式和当前状态一览。

---

## 1. 状态机直接映射（`StateMachine.stateSVGs`）

这些 SVG 由 `PetState` 枚举直接映射，在对应状态下自动展示。

| PetState | SVG 文件 | 触发条件 |
|----------|---------|---------|
| `.idle` | `clawd-idle-follow.svg` | 默认待机，JS 眼球追踪 |
| `.thinking` | `clawd-working-thinking.svg` | Claude 开始思考 |
| `.working` | `clawd-working-typing.svg` | 单个会话工作中 |
| `.working` (3+) | `clawd-working-building.svg` | 3 个以上活跃会话 |
| `.juggling` | `clawd-working-juggling.svg` | juggling 状态 |
| `.juggling` (2+) | `clawd-working-conducting.svg` | 2 个以上 juggling 会话 |
| `.sweeping` | `clawd-working-sweeping.svg` | context compacted 事件 |
| `.error` | `clawd-error.svg` | 错误发生 |
| `.attention` | `clawd-happy.svg` | 任务完成提醒 |
| `.notification` | `clawd-notification.svg` | 通知事件 |
| `.carrying` | `clawd-working-carrying.svg` | carrying 状态 |
| `.sleeping` | `clawd-sleeping.svg` | 深度睡眠 |
| `.yawning` | `clawd-idle-yawn.svg` | 入睡序列：打哈欠 |
| `.dozing` | `clawd-idle-doze.svg` | 入睡序列：打盹 |
| `.collapsing` | `clawd-collapse-sleep.svg` | 入睡序列：趴下 |
| `.waking` | `clawd-wake.svg` | 唤醒过渡 |
| `.miniIdle` | `clawd-mini-idle.svg` | Mini 模式默认待机 |
| `.miniEnter` | `clawd-mini-enter.svg` | Mini 模式入场 |
| `.miniPeek` | `clawd-mini-peek.svg` | Mini 模式鼠标 hover |
| `.miniAlert` | `clawd-mini-alert.svg` | Mini 模式警告 |
| `.miniHappy` | `clawd-mini-happy.svg` | Mini 模式开心 |
| `.miniCrabwalk` | `clawd-mini-crabwalk.svg` | Mini 模式横走 |
| `.miniEnterSleep` | `clawd-mini-enter-sleep.svg` | Mini 模式入睡过渡 |
| `.miniSleep` | `clawd-mini-sleep.svg` | Mini 模式睡眠 |

---

## 2. Idle 轮播池（`StateMachine.idleAnims`）

长时间无操作后（20s），从池中随机选一个播放，播放完回到 idle-follow。

| SVG 文件 | 持续时间 | 说明 |
|---------|---------|------|
| `clawd-idle-look.svg` | 6.5s | 左右张望 |
| `clawd-working-debugger.svg` | 14s | 调试表情 |
| `clawd-idle-reading.svg` | 14s | 阅读姿态 |
| `clawd-idle-living.svg` | 16s | 日常生活微动作（看四周、挠头、打哈欠） |
| `clawd-idle-music.svg` | 12s | 听音乐摇摆 |
| `clawd-crab-walking.svg` | 8s | 横着走路 |

---

## 3. 会话可指定的 display SVG（`allowedDisplaySvgs`）

Claude CLI 会话可通过 `display_svg` 字段指定这些 SVG 覆盖默认显示。

| SVG 文件 | 适用场景 |
|---------|---------|
| `clawd-working-typing.svg` | 正在打字编码 |
| `clawd-working-building.svg` | 构建/编译 |
| `clawd-working-juggling.svg` | 多任务处理 |
| `clawd-working-conducting.svg` | 编排多个任务 |
| `clawd-idle-reading.svg` | 阅读/分析代码 |
| `clawd-idle-look.svg` | 搜索/浏览 |
| `clawd-working-debugger.svg` | 调试中 |
| `clawd-working-thinking.svg` | 思考中 |
| `clawd-working-ultrathink.svg` | extended thinking / 深度推理 |
| `clawd-working-beacon.svg` | 搜索/网络请求 |
| `clawd-working-builder.svg` | 构建工程 |
| `clawd-working-confused.svg` | 困惑/难题 |
| `clawd-working-overheated.svg` | 长时间高强度工作 |
| `clawd-working-pushing.svg` | git push 等推送操作 |
| `clawd-working-success.svg` | 成功完成 |
| `clawd-working-wizard.svg` | 施展魔法（复杂操作） |

---

## 4. 点击反应池（`PetWindow`）

用户点击桌宠时触发。

| SVG 文件 | 触发方式 | 说明 |
|---------|---------|------|
| `clawd-react-left.svg` | 双击（点在左半边） | 向左看 |
| `clawd-react-right.svg` | 双击（点在右半边） | 向右看 |
| `clawd-react-salute.svg` | 双击（20% 概率） | 敬礼 |
| `clawd-react-annoyed.svg` | 双击（50% 概率 → 50%） | 不耐烦 |
| `clawd-dizzy.svg` | 双击（50% 概率 → 50%） | 头晕 |
| `clawd-react-double.svg` | 四连击（随机二选一） | 双重反应 |
| `clawd-react-double-jump.svg` | 四连击（随机二选一） | 跳跃反应 |
| `clawd-react-drag.svg` | 拖拽 | 被拖动 |

---

## 5. 其他用途

| SVG 文件 | 用途 |
|---------|------|
| `clawd-static-base.svg` | 状态栏 tray icon |

---

## 6. 预留（有文件但暂无出场）

| SVG 文件 | 预留用途 | 备注 |
|---------|---------|------|
| `clawd-disconnected.svg` | WebSocket 断连 | 需要新增 PetState |
| `clawd-going-away.svg` | 退出/关闭过渡动画 | 需要退出过渡机制 |
| `clawd-idle-collapse.svg` | — | 与 `collapse-sleep.svg` 功能重叠 |
| `clawd-mini-peek-up.svg` | Mini 模式变体 | 已有 `mini-peek.svg` |
