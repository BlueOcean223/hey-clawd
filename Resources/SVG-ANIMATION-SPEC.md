# Clawd SVG Animation Specification

> 本规范是给 AI（Gemini / Claude / GPT）的标准 prompt。
> 创建或修改任何 Clawd SVG 动画时，必须遵循本规范。

---

## 1. 角色基础

### 1.1 静态参考模型

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 15 16" width="300" height="320">
  <rect x="3" y="15" width="9" height="1" fill="#000" opacity="0.5"/>   <!-- 影子 -->
  <g fill="#DE886D">
    <rect x="2" y="6" width="11" height="7"/>                           <!-- 躯干 -->
    <rect x="0" y="9" width="2" height="2"/>                            <!-- 左臂 -->
    <rect x="13" y="9" width="2" height="2"/>                           <!-- 右臂 -->
    <rect x="3" y="13" width="1" height="2"/>                           <!-- 外左腿 -->
    <rect x="5" y="13" width="1" height="2"/>                           <!-- 内左腿 -->
    <rect x="9" y="13" width="1" height="2"/>                           <!-- 内右腿 -->
    <rect x="11" y="13" width="1" height="2"/>                          <!-- 外右腿 -->
  </g>
  <g fill="#000">
    <rect x="4" y="8" width="1" height="2"/>                            <!-- 左眼 -->
    <rect x="10" y="8" width="1" height="2"/>                           <!-- 右眼 -->
  </g>
</svg>
```

### 1.2 颜色规范

| 用途 | 色值 | 说明 |
|------|------|------|
| 身体/四肢 | `#DE886D` | 螃蟹主色 |
| 眼睛 | `#000000` | 纯黑 |
| 影子 | `#000000` opacity 0.4–0.6 | 半透明黑 |
| 代码/数据 | `#40C4FF` | 青色 |
| 成功/金色 | `#FFD700` `#FFC107` | 金/琥珀 |
| 错误/危险 | `#FF5252` `#FF3B30` | 红色 |
| 睡眠文字 | `#90A4AE` | 灰蓝 |
| 通知 | `#FFA000` | 橙色 |

### 1.3 动画画布

```
viewBox="-15 -25 45 45"  width="500"  height="500"
```

角色原始坐标仍在 (0,0)–(15,16) 区域内，扩展的 viewBox 为道具和特效留空间。

---

## 2. 分层架构（最核心的规则）

### 2.1 标准全身动画层级

```
<svg>
  <defs><style> ... </style></defs>

  ┌─ Layer 0: 影子（独立动画，跟随身体位移同步缩放）
  │    <rect id="shadow-js" class="shadow-anim" .../>
  │
  ├─ Layer 1: 腿（**静态或独立动画**，绝不放进 body 组）
  │    <g id="legs" fill="#DE886D">
  │      <rect x="3" y="13" width="1" height="2"/>   <!-- 外左腿 -->
  │      <rect x="5" y="13" width="1" height="2"/>   <!-- 内左腿 -->
  │      <rect x="9" y="13" width="1" height="2"/>   <!-- 内右腿 -->
  │      <rect x="11" y="13" width="1" height="2"/>  <!-- 外右腿 -->
  │    </g>
  │
  ├─ Layer 2: 身体主组（嵌套动画）
  │    <g id="body-js">                               <!-- JS 眼球追踪偏移 -->
  │      <g class="action-body">                      <!-- 主时间轴：倾斜/转身/拉伸 -->
  │        <g class="breathe-anim">                   <!-- 呼吸：3.2s 独立循环 -->
  │          ├─ <rect id="torso" .../>                <!-- 躯干 -->
  │          ├─ <g class="arm-l">                     <!-- 左臂（独立动画） -->
  │          │    <rect x="0" y="9" width="2" height="2"/>
  │          │  </g>
  │          ├─ <g class="arm-r">                     <!-- 右臂（独立动画） -->
  │          │    <rect x="13" y="9" width="2" height="2"/>
  │          │  </g>
  │          ├─ <g id="eyes-js">                      <!-- JS 眼球追踪 -->
  │          │    <g class="eyes-look">               <!-- CSS 眼球位移 -->
  │          │      <g class="eyes-blink">            <!-- CSS 眨眼 -->
  │          │        <rect x="4" y="8" .../>         <!-- 左眼 -->
  │          │        <rect x="10" y="8" .../>        <!-- 右眼 -->
  │          │      </g>
  │          │    </g>
  │          │  </g>
  │          └─ 嘴巴/泪滴/特效（可选）
  │        </g>
  │      </g>
  │    </g>
  │
  └─ Layer 3: 道具/环境（键盘、屏幕、粒子等）
```

### 2.2 关键规则

1. **腿必须独立于身体组** — 身体呼吸/倾斜时腿不应该跟着变形
2. **呼吸层必须嵌套在动作层内部** — `action-body > breathe-anim`，不是并列
3. **左右手臂各自独立动画** — 不要镜像同步，要有不对称感
4. **眼睛是三层结构** — `eyes-js`(运行时追踪) > `eyes-look`(CSS位移) > `eyes-blink`(CSS缩放)
5. **影子跟随身体动态变化** — 身体拉伸时影子变窄变淡，落地时变宽变亮

### 2.3 眼球追踪钩子 ID（必须保留）

以下 ID 供运行时 Core Animation 控制眼球追踪（通过 `CALayer.name` 查找），**支持眼球追踪的 SVG 必须包含**：

> `-js` 后缀是历史命名，实际已由 Core Animation 驱动，不涉及 JavaScript。所有 SVG 中保留此命名。

| ID | 用途 | 运行时行为 |
|----|------|-----------|
| `#eyes-js` | 眼球位置 | `translate(dx, dy)` 跟随鼠标 |
| `#body-js` | 身体微偏 | `translate(dx*0.33, dy*0.33)` 跟随鼠标 |
| `#shadow-js` | 影子拉伸 | `translate(shiftX, 0) scaleX(scale)` |

需要眼球追踪的 SVG（idle-follow、mini-idle、mini-peek 等）加上：
```css
#eyes-js, #body-js, #shadow-js {
  transition: transform 0.2s ease-out;
}
#shadow-js {
  transform-origin: 7.5px 15px;
}
```

**不需要眼球追踪的 SVG**（working、sleeping、reaction 等）可以省略这些 ID，用纯 CSS class。

---

## 3. 动画设计原则

### 3.1 "自然感"的三要素

#### A. 不同周期的叠加

永远不要让所有部位用同一个动画周期。最小配置：

| 动画层 | 标准周期 | 用途 |
|--------|---------|------|
| 呼吸 | 3.2s | 胸腔起伏（所有非睡眠状态通用） |
| 眨眼 | 4s–5s | 独立于呼吸，每周期 2-4 次 |
| 主动作 | 10s–18s | 看四周、挠头、打哈欠等 |
| 手臂细节 | 各自不同 | 左右臂用不同周期/相位 |

数学关系：主动作周期应该是呼吸周期的整数倍（16s = 5×3.2s），这样呼吸循环与主动作自然对齐。

#### B. 动作弧线（预备→动作→回落）

每个显著动作必须有完整弧线，不要突然出现/消失：

```
错误：0% 无 → 50% 出现 → 100% 无
正确：
  预备（2-3%）：身体微微反向蓄力
  动作（5-15%）：执行主运动
  高峰（2-5%）：保持/略过冲
  回落（5-10%）：减速回到静止
  缓冲（1-2%）：轻微反弹/晃动
```

#### C. 相位错开

对称元素（左右臂、多个粒子、多个 Zzz）必须错开启动时间：

```css
/* 用负 animation-delay 实现"一直在动"的感觉 */
.particle-1 { animation-delay: 0s; }
.particle-2 { animation-delay: -0.7s; }
.particle-3 { animation-delay: -1.4s; }
```

### 3.2 Transform-Origin 参考表

| 元素 | transform-origin | 说明 |
|------|-----------------|------|
| 身体主组 (action-body) | `7.5px 13px` | 躯干底部中心 |
| 呼吸层 (breathe-anim) | `7.5px 13px` | 同上 |
| 影子 | `7.5px 15.5px` | 地面接触点 |
| 眨眼 (eyes-blink) | `7.5px 9px` | 眼睛垂直中心 |
| 左臂 | `2px 10px` | 左肩关节（臂与躯干连接处） |
| 右臂 | `13px 10px` | 右肩关节 |
| 弹跳落地 | `7.5px 15px` | 脚底接地点 |

### 3.3 Easing 选择指南

| 场景 | Easing | 理由 |
|------|--------|------|
| 呼吸/摇摆 | `ease-in-out` | 自然的加减速 |
| 粒子上浮/代码滚动 | `linear` | 匀速运动 |
| 像素风闪烁/星星 | `step-end` | 帧动画感 |
| 弹跳落地 | `cubic-bezier(0.34, 1.56, 0.64, 1)` | 过冲回弹 |
| 一次性转场 | `ease-out` | 快起慢收 |

---

## 4. 动画类型模板

### 4.1 Idle 类（循环、低能量）

**代表文件**：clawd-idle-living.svg、clawd-idle-look.svg

**要求**：
- 主时间轴 10s–18s，内含多段微动作（看左、看右、挠头、打哈欠）
- 呼吸 3.2s 独立循环
- 眨眼 4s 独立循环
- 影子跟随身体缩放
- 腿静态
- 手臂不对称：左臂有挠头动作时，右臂保持静止或只在打哈欠时伸展

**Idle-living 时间轴模板（16s 循环）**：

```
0%-8%    静止（呼吸+眨眼）
10%-22%  看右（眼睛 translate +3px，身体微右倾 +1px）
24%-26%  回中
28%-36%  左臂挠头（3次快速上下）
38%-52%  看左（眼睛 -3px，身体微左倾 -1px）
55%-57%  回中
60%-76%  打哈欠（身体拉伸、嘴张开、双臂外伸、眼闭、泪滴）
78%      落地压扁（scaleY 0.95）
80%-100% 恢复静止
```

### 4.2 Working 类（循环、高能量）

**代表文件**：clawd-working-typing.svg、clawd-working-building.svg

**要求**：
- 手臂高频运动（0.12s–0.15s 打字，1.2s 锤击）
- 身体微振（0.3s–0.4s 轻微上下抖动）
- 呼吸层照常 3.2s
- 眼睛聚焦在工作对象上（周期性扫视）
- 道具有独立动画（键盘闪光、代码行滚动、锤子火花）
- 影子跟随身体节拍

**道具动画技巧**：
- 键盘按键闪光：每个键不同周期（0.5s–0.9s），用负 delay 错开
- 代码行：从左向右 scaleX 生长 → 停留 → translateY 向上滑出
- 数据粒子：`translateY(-17px) scale(0.5→1)` 上浮消失，4-7 个错开

### 4.3 Reaction 类（一次性、短促）

**代表文件**：clawd-react-left.svg、clawd-happy.svg

**要求**：
- `animation-fill-mode: forwards`（保持最终状态）
- `animation-iteration-count: 1`（不循环）
- 持续 2-4s
- 也要有眨眼（保持"活着感"，即使只播放 3 秒）
- 特效弹出（问号、感叹号、星星）有预备→弹出→消散弧线
- 负 animation-delay 可以让动画显得更紧凑

**Reaction 时间轴模板（2.5s 一次性）**：
```
0%-15%   预备（身体微微反方向蓄力）
16%-40%  主动作（转身、跳起）
40%-56%  保持姿态 + 特效弹出
56%-84%  回归
84%-100% 稳定（可以有轻微晃动）
```

### 4.4 Sleep 类（循环、极低能量）

**代表文件**：clawd-sleeping.svg

**要求**：
- 呼吸放慢到 4s–4.5s，幅度减小
- 眼睛关闭（scaleY(0.1) 或静态隐藏）
- Zzz 粒子上浮（3 个，各自不同曲线和速度，负 delay 错开）
- 身体扁平（"趴下"姿态）
- 影子更宽更暗（身体贴地）
- 四肢放松展开

### 4.5 Transition 类（一次性、连接状态）

**代表文件**：clawd-idle-yawn.svg、clawd-idle-collapse.svg、clawd-wake.svg

**要求**：
- `forwards` 填充模式
- 结束姿态必须匹配下一个状态的起始姿态
- 负 animation-delay 让转场更流畅
- wake 用 `cubic-bezier` 过冲弹回（弹簧感）

### 4.6 Mini 模式（屏幕边缘半隐藏）

**代表文件**：clawd-mini-idle.svg、clawd-mini-peek.svg

**特殊要求**：
- 整个角色倾斜 -12°（`rotate(-12deg)` 在最外层或以静态 transform 表示）
- 左臂加长（width 4.5px，x 从 -1.5 开始）伸向屏幕内侧
- **无影子**（角色贴着屏幕边缘，无地面）
- 需要 `#eyes-js` `#body-js` 供 JS 眼球追踪
- 手臂晃动周期长（25s），大部分时间静止，偶尔快速招手

---

## 5. CSS 编写规范

### 5.1 文件结构

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="-15 -25 45 45" width="500" height="500">
  <defs>
    <style>
      /* ===== 1. 独立子动画（呼吸、眨眼） ===== */
      .breathe-anim { ... }
      .eyes-blink { ... }

      /* ===== 2. 主时间轴动画 ===== */
      .action-body { ... }

      /* ===== 3. 部件动画（手臂、嘴巴） ===== */
      .arm-l { ... }
      .arm-r { ... }

      /* ===== 4. 特效动画（粒子、闪光） ===== */
      .particle { ... }

      /* ===== 5. JS 钩子样式（如需要） ===== */
      #eyes-js, #body-js, #shadow-js { ... }

      /* ===== Keyframes ===== */
      @keyframes breathe { ... }
      @keyframes eye-blink { ... }
      @keyframes action-body { ... }
      /* ... */
    </style>
  </defs>

  <!-- 几何体按分层顺序排列 -->
</svg>
```

### 5.2 命名约定

- Class 前缀统一：不需要前缀，直接语义化（`breathe-anim`、`arm-l`、`eyes-blink`）
- Keyframe 名 = `{动作}-{部位}`（`eye-blink`、`arm-l-idle`、`body-bounce`）
- 特效延迟用 class：`.d1`、`.d2`、`.d3`（不要用 style 属性内联 animation-delay）
- 特效粒子：`.t1`、`.t2`、`.t3` 或 `.sp1`、`.sp2`

### 5.3 关键帧编写规则

**状态保持技巧**（防止意外插值）：

```css
/* 错误：0% 和 35% 之间会产生意外过渡 */
@keyframes bad {
  0%, 35% { transform: translate(0, 0); }
  50% { transform: translate(5px, 0); }
}

/* 正确：显式标注每个状态的起止 */
@keyframes good {
  0%, 8%   { transform: scale(1, 1) translate(0, 0); }  /* 静止 */
  12%, 22% { transform: scale(1, 1) translate(1px, 0); } /* 右看 */
  26%, 38% { transform: scale(1, 1) translate(0, 0); }   /* 回中 */
}
```

**一次性动画**：
```css
.one-shot {
  animation: my-anim 2.5s ease-in-out forwards;
  animation-iteration-count: 1;
}
```

**负延迟预启动**：
```css
.pre-started {
  animation: collapse 0.8s ease-in -0.2s forwards;
  /* 渲染时已经走了 25%，显得更紧凑 */
}
```

---

## 6. 渲染引擎约束

Clawd 使用自研的 Core Animation 渲染管线（非浏览器），只支持以下 SVG/CSS 特性子集。**超出此范围的特性会被静默忽略，不会报错。**

详见 `docs/rendering-system.md`。

### 6.1 支持的 SVG 元素

| 元素 | 说明 |
|------|------|
| `<svg>` | viewBox、width/height |
| `<defs>` | 定义可复用节点 |
| `<style>` | CSS 规则（仅在 `<defs>` 内） |
| `<g>` | 分组，支持 id/class/fill/opacity/transform/clip-path |
| `<rect>` | 矩形，支持 x/y/width/height/rx/ry/fill/opacity/stroke |
| `<circle>` | 圆，支持 cx/cy/r |
| `<ellipse>` | 椭圆，支持 cx/cy/rx/ry |
| `<path>` | 路径，支持 d 属性（M/L/H/V/C/Q/A/Z） |
| `<polygon>` / `<polyline>` | 多边形，支持 points |
| `<line>` | 线段，支持 x1/y1/x2/y2 |
| `<use>` | 引用 defs 中的节点，支持 xlink:href/href |
| `<clipPath>` | 裁剪路径 |

### 6.2 支持的 CSS 动画属性

| 属性 | 说明 |
|------|------|
| `animation` | 简写和全部拆分属性（name/duration/timing-function/iteration-count/direction/delay/fill-mode） |
| `@keyframes` | 百分比停靠点，支持 from/to |
| `transform` | translate/translateX/translateY/scale/scaleX/scaleY/rotate |
| `transform-origin` | 像素、百分比、关键字（left/right/top/bottom/center） |
| `transform-box` | fill-box / view-box |
| `transition` | 用于 `#eyes-js` 等追踪元素的平滑过渡 |
| `opacity` | 透明度动画 |
| `visibility` | 可见性切换（配合 step-end） |
| `fill` | 颜色动画 |
| `stroke` / `stroke-width` | 描边动画 |
| `r` | circle 半径动画 |
| `width` | 宽度动画 |

**Timing functions**：`ease-in-out`、`linear`、`ease-out`、`ease-in`、`step-end`、`cubic-bezier(x1,y1,x2,y2)`

### 6.3 不支持（禁止使用）

| 特性 | 替代方案 |
|------|---------|
| `<linearGradient>` / `<radialGradient>` | 用多个 `<rect>` 分色块近似 |
| `<filter>` (blur/shadow/glow) | 用半透明 `<rect>` 模拟 |
| `<text>` / `<tspan>` | 用像素点阵 `<rect>` 拼字 |
| `<image>` | 不支持外部图片 |
| `<foreignObject>` | 不支持 |
| `<mask>` (SVG mask 元素) | 用 `<clipPath>` 替代 |
| CSS 组合选择器 | 只支持 `.class` 和 `#id`，不支持 `.a .b`、`.a > .b` |
| CSS `@media` / `@supports` | 不支持 |
| CSS `filter` 属性 | 不支持 |
| CSS 变量 (`var(--x)`) | 不支持 |
| `skewX` / `skewY` / `matrix` | 不常用，避免使用 |

---

## 7. 质量检查清单

完成一个 SVG 后，逐项检查：

- [ ] **只使用了支持的 SVG/CSS 特性？** — 对照 §6 渲染引擎约束，禁止 gradient/filter/text 等
- [ ] **腿是否独立于身体组？** — 身体呼吸/倾斜时腿不跟着变形
- [ ] **有眨眼吗？** — 除了睡眠/闭眼状态，所有动画都必须有 3-5s 周期的眨眼
- [ ] **影子是动态的吗？** — 跟随身体缩放/位移变化
- [ ] **左右臂动画不对称吗？** — 不能完美镜像同步
- [ ] **呼吸周期是 3.2s 吗？** — 与主时间轴形成整数倍关系
- [ ] **有动作弧线吗？** — 每个显著动作有预备→执行→回落
- [ ] **easing 选择合理吗？** — 不是所有东西都 ease-in-out
- [ ] **粒子/特效有相位错开吗？** — 用负 animation-delay
- [ ] **需要追踪钩子的 SVG 有 `#eyes-js` `#body-js` `#shadow-js` 吗？**
- [ ] **CSS 写在 `<defs><style>` 里吗？** — 不要内联 style 属性
- [ ] **没有多余的嵌套 `<style>` 块吗？** — 只在 `<defs>` 里有一个
- [ ] **viewBox 是 `-15 -25 45 45`、尺寸 `500x500` 吗？**

---

## 8. 按文件逐个任务指令

当需要创建/重写某个具体 SVG 时，使用以下 prompt 模板：

```
请按照 SVG-ANIMATION-SPEC.md 规范，创建/重写 [文件名].svg。

动画类型：[idle循环 / working循环 / reaction一次性 / sleep循环 / transition一次性 / mini模式]
主时间轴周期：[Xs]
是否需要眼球追踪钩子：[是/否]

动画内容描述：
[用文字描述这个动画要表达什么情绪/动作]

时间轴设计（每个时间段对应的动作）：
0%-X%: [描述]
X%-Y%: [描述]
...

涉及的特效：
- [特效1描述]
- [特效2描述]

参考：请严格遵循规范中的分层架构、transform-origin 表、easing 选择指南。
先输出完整的时间轴规划（文字），确认后再输出 SVG 代码。
```

---

## 9. 常见错误与修复

| 错误 | 表现 | 修复 |
|------|------|------|
| 腿在身体组内 | 呼吸时腿跟着缩放变形 | 腿移到 body-js 外面 |
| 没有眨眼 | 角色看起来"死了" | 加 `eyes-blink` 层，4s 周期 |
| 影子静态 | 动作缺乏重量感 | 影子 scaleX+opacity 跟随身体 |
| 手臂完全同步 | 机械感，像机器人 | 左右臂用不同周期或不同关键帧 |
| 所有动画同一 easing | 缺乏层次感 | 身体 ease-in-out，粒子 linear，闪烁 step-end |
| visibility: hidden 做切换 | 没有过渡的突然消失 | 需要渐变用 opacity，需要瞬切用 step-end + visibility |
| 呼吸和动作写在同一个元素上 | CSS 动画属性冲突 | 呼吸嵌套在动作内部，不是 comma-separated 在一个 animation 里 |
| 一次性动画没有 forwards | 播完跳回第一帧 | 加 `animation-fill-mode: forwards` |
| 特效同时启动 | 看起来像"数据爆炸" | 用负 animation-delay 错开 |

---

## 附录 A：呼吸动画标准实现

```css
.breathe-anim {
  transform-origin: 7.5px 13px;
  animation: breathe 3.2s infinite ease-in-out;
}
@keyframes breathe {
  0%, 100% { transform: scale(1, 1) translate(0, 0); }
  50%      { transform: scale(1.02, 0.98) translate(0, 0.5px); }
}
```

## 附录 B：标准眨眼实现

```css
.eyes-blink {
  transform-origin: 7.5px 9px;
  animation: eye-blink 4s infinite ease-in-out;
}
@keyframes eye-blink {
  0%, 10%, 100% { transform: scaleY(1); }
  5%            { transform: scaleY(0.1); }
}
```

可以在主时间轴的特定时段覆盖眨眼（如打哈欠时闭眼）：
```css
@keyframes eye-blink-with-yawn {
  0%, 10%, 58%, 76%, 100% { transform: scaleY(1); }
  5%                       { transform: scaleY(0.1); }  /* 普通眨眼 */
  60%, 72%                 { transform: scaleY(0.1); }  /* 哈欠闭眼 */
}
```

## 附录 C：标准影子动画

```css
.shadow-anim {
  transform-origin: 7.5px 15.5px;
  animation: shadow-action [主时间轴周期] infinite ease-in-out;
}
@keyframes shadow-action {
  /* 静止 */
  0%, 8%, 26%, 55%, 80%, 100% { transform: scaleX(1) translate(0, 0); opacity: 0.5; }
  /* 右倾 */
  12%, 22% { transform: scaleX(1) translate(1px, 0); opacity: 0.5; }
  /* 左倾 */
  42%, 50% { transform: scaleX(1) translate(-1px, 0); opacity: 0.5; }
  /* 拉伸（如跳起/哈欠） */
  65% { transform: scaleX(0.9) translate(0, 0); opacity: 0.4; }
  /* 压扁（如落地） */
  72% { transform: scaleX(1.05) translate(0, 0); opacity: 0.55; }
}
```

## 附录 D：完整参考实现（clawd-idle-follow.svg）

这是最简单但最重要的文件——纯呼吸+眨眼+JS眼球追踪：

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="-15 -25 45 45" width="500" height="500">
  <defs>
    <style>
      .breathe-anim {
        transform-origin: 7.5px 13px;
        animation: breathe 3.2s infinite ease-in-out;
      }
      .eyes-blink {
        transform-origin: 7.5px 9px;
        animation: eye-blink 4s infinite ease-in-out;
      }
      #eyes-js, #body-js, #shadow-js {
        transition: transform 0.2s ease-out;
      }
      #shadow-js {
        transform-origin: 7.5px 15px;
      }
      @keyframes breathe {
        0%, 100% { transform: scale(1, 1) translate(0, 0); }
        50%      { transform: scale(1.02, 0.98) translate(0, 0.5px); }
      }
      @keyframes eye-blink {
        0%, 10%, 100% { transform: scaleY(1); }
        5%            { transform: scaleY(0.1); }
      }
    </style>
  </defs>

  <!-- Layer 0: Shadow -->
  <g id="shadow-js">
    <rect x="3" y="15" width="9" height="1" fill="#000" opacity="0.5"/>
  </g>

  <!-- Layer 1: Legs (static, independent) -->
  <g id="legs" fill="#DE886D">
    <rect x="3" y="11" width="1" height="4"/>
    <rect x="5" y="11" width="1" height="4"/>
    <rect x="9" y="11" width="1" height="4"/>
    <rect x="11" y="11" width="1" height="4"/>
  </g>

  <!-- Layer 2: Upper Body -->
  <g id="body-js">
    <g class="breathe-anim">
      <rect id="torso" x="2" y="6" width="11" height="7" fill="#DE886D"/>
      <rect x="0" y="9" width="2" height="2" fill="#DE886D"/>
      <rect x="13" y="9" width="2" height="2" fill="#DE886D"/>
      <g id="eyes-js" fill="#000">
        <g class="eyes-blink">
          <rect x="4" y="8" width="1" height="2"/>
          <rect x="10" y="8" width="1" height="2"/>
        </g>
      </g>
    </g>
  </g>
</svg>
```
