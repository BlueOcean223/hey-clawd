# 渲染系统：从 WKWebView 到 Core Animation

> Clawd 桌宠的渲染核心——如何用原生 Core Animation 替代 WKWebView 进程组，
> 将内存从 ~80 MB 压到 ~16 MB，idle CPU 从 ~8% 降到  1%。

---

## 1. 为什么要重写渲染层

桌宠的视觉本质是：加载一个 SVG → 渲染成像素 → 播放 CSS keyframe 动画 → 实时追踪鼠标移动眼球。

最初的实现用 WKWebView 承载一个 `bridge.html` 页面，通过 `evaluateJavaScript()` 桥接 SVG 的加载、动画和交互。这个方案在功能上是完整的——但代价极高：

| 问题 | 量化 |
|------|------|
| 进程膨胀 | WKWebView 启动 3-4 个子进程（WebContent / GPU / Networking），一个桌宠就是一个小型浏览器 |
| 内存浪费 | 主进程 + 子进程合计 ~80-120 MB RSS，一个 15×16 像素的螃蟹在消耗一个 Electron 应用的资源 |
| CPU 空转 | JS 事件循环 + compositor 常驻 ~3-8% idle CPU，30Hz 命中检测轮询雪上加霜 |
| 切换延迟 | SVG 切换路径：JS eval → DOM mutation → CSS reflow，单次 ~30-80ms |
| 冷启动慢 | WebView 初始化 + HTML 加载 + JS 求值：~200-500ms |

桌宠应该是安静的——它常驻桌面，用户不应该在活动监视器里注意到它的存在。轻量、低占用、低能耗才应该是桌宠的特征。可惜的是 WKWebView 方案违背了这个特征。

重写渲染层的动机很简单：桌宠只需要解析 SVG 几何 → 建 layer 树 → 挂 keyframe 动画。这三件事 Core Animation 原生支持，零 IPC 开销。

---

## 2. 架构总览

```
SVG 文件 (.svg)
    │
    ▼
┌──────────────────────────────────────────────────────┐
│  SVGParser                                           │
│  XMLParser → SVGDocument (节点树 + CSS 动画绑定)      │
│  CSSParser → @keyframes / animation bindings         │
└──────────────────────┬───────────────────────────────┘
                       │ SVGDocument
                       ▼
┌──────────────────────────────────────────────────────┐
│  CALayerRenderer                                     │
│  SVGNode → CALayer 树 (rect→CALayer, path→CAShapeLayer) │
│  viewBox 坐标系 → macOS 坐标系                         │
│  命中检测 (hitTest)                                    │
└──────────────────────┬───────────────────────────────┘
                       │ CALayer 树
                       ▼
┌──────────────────────────────────────────────────────┐
│  CAAnimationBuilder                                  │
│  CSS @keyframes → CAKeyframeAnimation                │
│  多属性 → CAAnimationGroup                            │
│  timing / delay / fillMode 一一映射                   │
└──────────────────────┬───────────────────────────────┘
                       │ 带动画的 CALayer 树
                       ▼
┌──────────────────────────────────────────────────────┐
│  PetView (NSView)                                    │
│  SVG 加载 / 交叉淡入淡出 / 命中检测 / 眼球追踪        │
│  ┌──────────────────────────────────────────────┐    │
│  │  EyeTracker (10Hz DispatchSourceTimer)       │    │
│  │  鼠标位置 → CATransaction → 眼球 layer 位移    │    │
│  └──────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────┘
```

**关键设计决策**：SVG 文件同时作为设计源文件和运行时数据格式。设计师在浏览器中预览 SVG，应用在运行时解析同一份文件。没有中间编译步骤，没有格式转换。

---

## 3. SVG Parser：从 XML 到数据结构

**核心文件**：`Sources/Core/SVG/SVGParser.swift`、`Sources/Core/SVG/CSSParser.swift`

### 3.1 数据模型

```swift
struct SVGDocument: Sendable {
    let viewBox: CGRect
    let defs: [String: SVGNode]           // <defs> 中 id → 节点
    let rootChildren: [SVGNode]
    let animations: [String: SVGAnimation] // @keyframes 名 → 关键帧序列
    let animationBindings: [SVGAnimationBinding]  // CSS 选择器 → 动画绑定
    let transitions: [String: [SVGTransition]]
}
```

`SVGNode` 是 indirect enum，覆盖审计确认的元素子集：`group`、`rect`、`circle`、`ellipse`、`path`、`polygon`、`polyline`、`line`、`use`、`clipPath`。不实现完整 SVG 规范——只解析 桌宠 SVG 实际使用的特性。

### 3.2 两阶段解析

```
阶段 1：XML 结构解析
  XMLParser (Foundation) → XMLTreeBuilder (delegate)
    → 构建 SVGNode 树
    → 收集 <style> 块文本
    → 注册 <defs> 元素到查找表
    → 处理命名空间属性 (xlink:href)

阶段 2：CSS 规则解析
  CSSParser.parse(styleText)
    → 解析选择器 (.class / #id，不需要组合选择器)
    → 解析 animation 简写和拆分属性
    → 解析 @keyframes 块 (百分比 → offset)
    → 解析 transform-origin (关键字 / 像素 / 百分比)
    → 解析 transition (用于眼球追踪元素)
    → 解析内联 style 属性
```

CSS Parser 支持 `animation` 简写的完整拆解——name、duration、timing-function、iteration-count、direction、delay、fill-mode，以及多动画逗号分隔语法。Timing function 支持标准命名函数和 `cubic-bezier(x1, y1, x2, y2)` 自定义曲线。

### 3.3 LRU 缓存

**核心文件**：`Sources/Core/SVG/SVGDocumentCache.swift`

```swift
@MainActor
final class SVGDocumentCache {
    static let shared = SVGDocumentCache()
    private var cache: [String: SVGDocument] = [:]
    private var accessOrder: [String] = []
    private let capacity = 5
}
```

容量 5 个文档，LRU 淘汰。命中缓存时切换延迟从 ~10ms（解析）降到 < 3ms（直接取用）。桌宠常驻 idle-follow 和 working 两三个状态，缓存命中率很高。

**性能对比**：

| 场景 | WKWebView | Core Animation | 提升 |
|------|-----------|----------------|------|
| 冷启动（首次 SVG） | ~200-500ms（WebView init + HTML + JS） | ~10-30ms（XML 解析 + layer 构建） | ~95% |
| 热切换（缓存命中） | ~30-80ms（JS eval + DOM diff） | < 3ms（缓存 SVGDocument + layer 构建） | ~95% |

---

## 4. CALayer 渲染器：从数据结构到像素

**核心文件**：`Sources/Core/SVG/CALayerRenderer.swift`

### 4.1 元素映射

| SVG 元素 | CALayer 类型 | 映射方式 |
|----------|-------------|---------|
| `<svg>` | CALayer | bounds = viewBox，sublayerTransform 处理负偏移 |
| `<g>` | CALayer | 纯容器，传递 opacity / transform / clip-path |
| `<rect>` | CALayer | bounds = 尺寸，backgroundColor = fill，cornerRadius |
| `<circle>` / `<ellipse>` | CAShapeLayer | 椭圆 path + fillColor |
| `<path>` | CAShapeLayer | 解析 `d` 属性的完整路径语法 |
| `<polygon>` / `<polyline>` | CAShapeLayer | 解析 `points` 字符串 |
| `<line>` | CAShapeLayer | 线段 path |
| `<use>` | CALayer | 展开 defs 引用 → 递归生成子树 |
| `<clipPath>` | CALayer | 作为 mask layer（黑色填充） |

### 4.2 坐标系处理

桌宠的标准 viewBox 是 `"-15 -25 45 45"`——带负偏移。角色原始坐标在 `(0,0)-(15,16)` 区域，扩展区域留给道具和特效。

```swift
// 根 layer 通过 sublayerTransform 平移坐标原点
if viewBox.origin != .zero {
    rootLayer.sublayerTransform = CATransform3DMakeTranslation(
        -viewBox.origin.x, -viewBox.origin.y, 0
    )
}
```

SVG 的 transform 作用于 `(0,0)` 点，而 CALayer 的 transform 作用于 anchorPoint。渲染器通过补偿变换保持一致：`T_ca = translate(pos) · T_svg · translate(-pos)`。

### 4.3 transform-origin：最棘手的映射

CSS `transform-origin` 有两种参考框架：
- **fill-box**（默认）：相对于元素自身的 bounds
- **view-box**：相对于 SVG 的 viewBox 坐标

渲染器需要将像素/百分比/关键字（`left`、`center`、`bottom`）统一换算为 CALayer 的 anchorPoint（归一化 0~1），同时调整 position 以保持视觉位置不变。对于零宽或零高的 layer（如线段），还需要从子元素推算 bounding box。

### 4.4 fill 继承

SVG 的 `<g fill="#DE886D">` 会向下继承颜色到所有子元素（除非子节点自己指定了 fill）。渲染器在递归构建子树时传递继承的 fill 值。

### 4.5 辅助解析器

| 解析器 | 文件 | 职责 |
|--------|------|------|
| TransformParser | `Sources/Core/SVG/TransformParser.swift` | translate/scale/rotate/skew/matrix → CATransform3D |
| ColorParser | `Sources/Core/SVG/ColorParser.swift` | `#hex` / `rgba()` / 命名色 → CGColor |
| PathParser | `Sources/Core/SVG/PathParser.swift` | SVG `d` 属性 → CGPath（M/L/H/V/C/Q/A/Z 命令） |

---

## 5. 动画引擎：CSS @keyframes → Core Animation

**核心文件**：`Sources/Core/SVG/CAAnimationBuilder.swift`

### 5.1 映射规则

| CSS | Core Animation |
|-----|---------------|
| `@keyframes name` | `CAKeyframeAnimation(keyPath:)` |
| 百分比停靠点 | `keyTimes` (0~1 数组) + `values` 数组 |
| `animation-duration` | `duration` |
| `ease-in-out` / `linear` / `ease-out` | `CAMediaTimingFunction(name:)` |
| `cubic-bezier(x1,y1,x2,y2)` | `CAMediaTimingFunction(controlPoints:)` |
| `step-end` | discrete `calculationMode` |
| `infinite` | `repeatCount = .infinity` |
| `forwards` | `fillMode = .forwards` + `isRemovedOnCompletion = false` |
| `animation-delay` | `beginTime = CACurrentMediaTime() + delay` |
| `alternate` / `alternate-reverse` | `autoreverses = true` |
| `reverse` | keyTimes 反转 (1 - offset) |

### 5.2 可动画属性

引擎支持 7 种属性的 keyframe 动画：

| CSS 属性 | CA keyPath | 值类型 |
|----------|-----------|--------|
| `transform` | `"transform"` | `CATransform3D` |
| `opacity` | `"opacity"` | `Float` |
| `fill` | `"backgroundColor"` / `"fillColor"` | `CGColor` |
| `visibility` | `"hidden"` | `Bool` |
| `stroke-width` | `"lineWidth"` | `CGFloat` |
| `r` (circle 半径) | `"path"` | `CGPath` |
| `width` | `"bounds.size.width"` | `CGFloat` |

### 5.3 多属性动画分组

一个 CSS `@keyframes` 可以同时动画 `transform` 和 `opacity`。引擎按属性拆分成独立的 `CAKeyframeAnimation`，再包进 `CAAnimationGroup` 同步播放：

```
@keyframes breathe {
    0%   { transform: scale(1); opacity: 1 }
    50%  { transform: scale(1.02, 0.98); opacity: 0.95 }
    100% { transform: scale(1); opacity: 1 }
}
        ↓
CAAnimationGroup {
    CAKeyframeAnimation(keyPath: "transform")
        keyTimes: [0, 0.5, 1]
        values: [identity, scale(1.02,0.98), identity]
    CAKeyframeAnimation(keyPath: "opacity")
        keyTimes: [0, 0.5, 1]
        values: [1.0, 0.95, 1.0]
    duration: 3.2s
    repeatCount: .infinity
}
```

### 5.4 关键帧归一化

Core Animation 要求 `keyTimes[0] == 0` 且 `keyTimes[last] == 1`。如果 CSS 的 keyframes 从 50% 开始或不到 100% 结束，引擎会在端点补齐持续值，确保 CA 兼容。

### 5.5 动画应用流程

```
CAAnimationBuilder.apply(document, rootLayer)
  → 合并 CSS 和 inline 动画绑定
  → 对每个绑定：通过选择器 (.class / #id) 找到目标 layer
  → 对每个 layer：从 SVGAnimation 构建 CAAnimation
  → 应用 transform-origin 调整
  → layer.add(animation, forKey: animationName)
```

---

## 6. PetView：把一切组装起来

**核心文件**：`Sources/Window/PetView.swift`

### 6.1 SVG 加载流水线

```
PetView.switchSVG(filename)
  → SVGDocumentCache.get(filename)     // 缓存命中？
  ?: Bundle 读文件 → SVGParser.parse() → SVGDocumentCache.set()
  → CALayerRenderer.build(document)     // 构建 layer 树
  → CAAnimationBuilder.apply(document, rootLayer)  // 挂载动画
  → 交叉淡入淡出：新 layer 0→1, 旧 layer 1→0 (120ms)
  → 定位特殊 layer (eyesLayer / bodyLayer / shadowLayer，通过 layer.name)
```

### 6.2 命中检测：从轮询到事件驱动

旧方案：`bridge.js` 里 30Hz Timer 轮询 `hitTestAt()`，通过 JS 桥接告知 Swift 鼠标是否在角色身上。

新方案：

```
NSTrackingArea (mouseMoved / mouseEntered / mouseExited)
  → PetView.performHitTest(point)
    → 坐标转换：view 坐标 → layer 坐标
    → CALayerRenderer.hitTest(layer, point)
      → 递归遍历 layer 树（倒序，z-order 优先）
      → CAShapeLayer：检查 fill path + stroked outline
      → 普通 layer：检查 bounds 包含
    → 命中非透明 layer → window.ignoresMouseEvents = false
    → 全透明 → window.ignoresMouseEvents = true
```

PetView 缓存上次命中检测结果，2 像素容差内直接复用，避免每次 mouseMoved 都遍历 layer 树。一个 200ms 恢复定时器处理窗口从透明变回可交互的边界情况。

**性能对比**：30Hz 轮询 + JS 桥接 → 事件驱动 + 原生 layer hitTest。idle 时零开销——没有鼠标事件就没有计算。

### 6.3 眼球追踪

**核心文件**：`Sources/Window/EyeTracker.swift`

EyeTracker 通过 DispatchSourceTimer 每 100ms（10Hz）采样鼠标位置，计算眼球偏移：

```
relX = cursor.x - eyeCenter.x
relY = cursor.y - eyeCenter.y
distance = hypot(relX, relY)
scale = min(1, distance / 300)       // 300pt 最大追踪距离
dx = (relX / distance) * 3 * scale   // 最大 3pt 水平偏移
dy = (relY / distance) * 1.5 * scale // 最大 1.5pt 垂直偏移
// 0.5pt 量化步长，减少抖动
```

偏移通过 `CATransaction` 直接赋值给眼球 layer 的 `transform`：

```swift
CATransaction.begin()
CATransaction.setAnimationDuration(0.2)
CATransaction.setAnimationTimingFunction(.init(name: .easeOut))
eyesLayer?.transform = CATransform3DMakeTranslation(dx, dy, 0)
CATransaction.commit()
```

0.2s 的 ease-out 过渡本身就能平滑 10Hz 的离散采样，不需要更高频率。旧方案 20Hz + JS 桥接反而更卡。

**节能设计**：
- 只在 follow 类 SVG（`clawd-idle-follow.svg`、`clawd-mini-idle.svg`）时激活
- `shouldTrackEyes = false` 时 suspend timer → 完全不唤醒主线程
- 窗口遮挡时暂停

### 6.4 窗口遮挡检测

**核心文件**：`Sources/Window/PetWindow.swift`

监听 `NSWindow.didChangeOcclusionStateNotification`：

- **窗口被遮挡**（切 Space、被覆盖）：所有 CALayer 的 `speed` 设为 0，暂停 EyeTracker
- **窗口重新可见**：恢复动画，通过 `beginTime` 补偿精确恢复到暂停时刻

动画完全由 WindowServer 的 render server 驱动——暂停/恢复是告诉 render server "不用画了"，主进程零开销。

### 6.5 Mini 模式镜像

```swift
// 左侧 mini 模式：水平翻转整个 layer 树
rootLayer.sublayerTransform = CATransform3DMakeScale(-1, 1, 1)
```

一行代码，不需要重新解析 SVG 或重建 layer。

---

## 7. 性能：数字说话

| 指标 | WKWebView | Core Animation | 改善幅度 |
|------|-----------|----------------|---------|
| 进程数 | 3-4（main + WebContent + GPU + Networking） | 1 | 消除全部辅助进程 |
| RSS 内存 | ~80-120 MB（含子进程） | ~15-25 MB | ~80% |
| Idle CPU | ~3-8%（JS 事件循环 + compositor + 30Hz 轮询） | < 1%（CAAnimation 硬件加速） | ~85% |
| 动画切换 | ~30-80ms（JS eval + DOM + reflow） | < 5ms（CALayer tree swap） | ~90% |
| 冷启动 | ~200-500ms | ~10-30ms | ~95% |
| 热切换 | ~30-80ms | < 3ms（LRU 缓存命中） | ~95% |

这些改善不来自"优化"——来自**消除不必要的层**。不需要 HTML 引擎就不加载 HTML 引擎。不需要 JS 运行时就不启动 JS 运行时。不需要 IPC 就不走 IPC。

### 7.1 CPU 零开销的秘密

CAAnimation 一旦挂载到 layer 上，动画帧的计算和渲染全部由 WindowServer 的 render server 完成——这是一个独立的系统进程，不算在应用的 CPU 里。应用只在状态切换时做一次 layer 树构建，之后主线程除了 10Hz 的眼球追踪采样外完全空闲。

窗口遮挡时连 render server 都不画了（`layer.speed = 0`）。笔记本合盖？零功耗。

### 7.2 内存精简的来源

| 组件 | WKWebView 方案 | Core Animation 方案 |
|------|---------------|-------------------|
| WebKit 框架 | ~30 MB（WebContent 进程） | 不加载 |
| JavaScript 引擎 | ~15 MB（JavaScriptCore） | 不加载 |
| DOM + CSS 引擎 | ~10 MB | 不加载 |
| GPU 进程 | ~20 MB | 不需要独立进程 |
| 网络栈进程 | ~8 MB | 不加载 |
| SVG 数据 | HTML + JS + SVG | SVGDocument 结构体（几 KB） |
| Layer 树 | WebKit compositor 管理 | CALayer 直接挂在 WindowServer |

---

## 8. 设计权衡

### 选择不实现完整 SVG 规范

SVGParser 只处理 桌宠 SVG 实际使用的特性子集。完整 SVG 规范包含滤镜、渐变、文本排版、foreignObject 等大量特性，实现它们等于重写半个浏览器引擎。

**约束**：新增 SVG 动画如果用了未支持的特性，需要先扩展 parser。SVG 能力审计锁定了支持范围。

### SVG 作为唯一源文件格式

没有中间编译步骤（如 SVG → JSON → 运行时格式）。好处是设计师改完 SVG 直接在浏览器预览，保存后应用下次加载即生效。代价是每次冷启动需要 XML 解析，但 LRU 缓存和 ~10ms 的解析时间让这个代价可以忽略。

### Sendable 数据模型

`SVGDocument` 和所有 `SVGNode` 类型都是 `Sendable`。虽然当前解析和渲染都在 MainActor 上，但数据模型的线程安全性为未来可能的后台预解析留了空间——不需要时不用，但用时不需要重构。

---

## 9. 核心文件索引

| 文件 | 职责 |
|------|------|
| `Sources/Core/SVG/SVGParser.swift` | XML → SVGDocument，两阶段解析 |
| `Sources/Core/SVG/CSSParser.swift` | CSS 规则 + @keyframes 解析 |
| `Sources/Core/SVG/SVGDocumentCache.swift` | LRU 缓存（容量 5） |
| `Sources/Core/SVG/CALayerRenderer.swift` | SVGDocument → CALayer 树 + 命中检测 |
| `Sources/Core/SVG/CAAnimationBuilder.swift` | CSS 动画 → CAKeyframeAnimation |
| `Sources/Core/SVG/TransformParser.swift` | CSS transform 函数 → CATransform3D |
| `Sources/Core/SVG/ColorParser.swift` | 颜色字符串 → CGColor |
| `Sources/Core/SVG/PathParser.swift` | SVG path `d` → CGPath |
| `Sources/Window/PetView.swift` | NSView，SVG 加载 / 命中检测 / 眼球追踪 |
| `Sources/Window/EyeTracker.swift` | 鼠标追踪 → 眼球偏移 (10Hz) |
| `Sources/Window/PetWindow.swift` | 透明浮动窗口，遮挡检测 / 拖拽 / 点击反应 |
