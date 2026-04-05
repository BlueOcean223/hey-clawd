// bridge.js — Swift ↔ WKWebView 桥接层
//
// 职责：
//   1. 接收 Swift 传入的 SVG markup，内联挂载到 DOM（不用 <object>，规避 contentDocument 跨域问题）
//   2. 提供 hitTestAt(x, y) 供 Swift 30Hz 轮询，判断鼠标是否落在桌宠实体像素上
//   3. 通过 webkit.messageHandlers 向 Swift 回报生命周期事件（bridge-ready / svg-loaded / svg-error）
//
// 坐标约定：所有从 Swift 传入的 (x, y) 均为 CSS viewport 坐标（Y 轴向下），Swift 侧已完成 AppKit→CSS 翻转。

(function () {
  const container = document.getElementById("pet-container");
  let currentSVG = null;
  let pendingSVG = null;
  // 单调递增的加载 ID，用于丢弃过期的异步回调。
  let currentLoadID = 0;
  // hitTestGeometry 的缓存，SVG 切换时清空。
  let cachedGeometryElements = null;

  // ── JS → Swift 消息通道 ──

  function postMessage(type, payload = {}) {
    const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge;
    if (!bridge) {
      return;
    }

    bridge.postMessage({ type, ...payload });
  }

  // ── SVG 生命周期 ──

  function releaseSVG(svgEl) {
    if (!svgEl) {
      return;
    }

    svgEl.remove();
  }

  // 统一设置内联 SVG 的 DOM 属性，确保命中检测和淡入动画正常工作。
  function normalizeInlineSVG(svgEl, filename) {
    svgEl.id = "clawd";
    svgEl.dataset.filename = filename;
    svgEl.style.opacity = "0";
    svgEl.style.transition = "opacity 120ms linear";
    // 必须显式 auto——否则 document.elementFromPoint() 会跳过整棵 SVG 子树。
    svgEl.style.pointerEvents = "auto";
    svgEl.setAttribute("preserveAspectRatio", svgEl.getAttribute("preserveAspectRatio") || "xMidYMid meet");
  }

  // 提交新 SVG：移除旧节点，清空几何缓存，通知 Swift。
  function swapSVG(nextSVG, filename, loadID) {
    if (pendingSVG !== nextSVG || currentLoadID !== loadID) {
      return;
    }

    nextSVG.style.transition = "none";
    nextSVG.style.opacity = "1";

    if (currentSVG && currentSVG !== nextSVG) {
      releaseSVG(currentSVG);
    }

    pendingSVG = null;
    currentSVG = nextSVG;
    cachedGeometryElements = null;
    postMessage("svg-loaded", { filename });
  }

  // Swift 调用入口：传入文件名 + SVG 原文，DOMParser 解析后内联挂载。
  function mountSVG(filename, markup) {
    if (!filename || !markup) {
      return;
    }

    // 同一 SVG 不重复挂载。
    if (currentSVG && currentSVG.dataset.filename === filename) {
      return;
    }

    if (pendingSVG) {
      releaseSVG(pendingSVG);
      pendingSVG = null;
    }

    // loadID 防竞态：快速连续调用 mountSVG 时，只有最后一次生效。
    const loadID = currentLoadID + 1;
    currentLoadID = loadID;

    try {
      const parsed = new window.DOMParser().parseFromString(markup, "image/svg+xml");
      const parsedRoot = parsed.documentElement;
      if (!parsedRoot || parsedRoot.nodeName.toLowerCase() !== "svg") {
        throw new Error("invalid svg root");
      }

      // importNode 将 SVG 从解析器文档搬到当前文档，保留完整子树。
      const nextSVG = document.importNode(parsedRoot, true);
      normalizeInlineSVG(nextSVG, filename);
      container.appendChild(nextSVG);
      pendingSVG = nextSVG;

      // 等一帧让浏览器完成 layout，再提交切换。
      window.requestAnimationFrame(function () {
        swapSVG(nextSVG, filename, loadID);
      });
    } catch (error) {
      if (currentLoadID !== loadID) {
        return;
      }

      postMessage("svg-error", {
        filename,
        message: error && error.message ? error.message : String(error)
      });
    }
  }

  // ── 命中检测 ──

  // 判断元素是否在 <defs> 内（模板定义，不直接渲染）。
  function isInsideDefs(el) {
    var node = el.parentNode;
    while (node) {
      if (node.nodeName.toLowerCase() === "defs") {
        return true;
      }
      node = node.parentNode;
    }
    return false;
  }

  // 收集并缓存 SVG 内可命中的 SVGGeometryElement。
  // 排除 <defs> 内的模板元素（通过 <use> 引用，不直接参与渲染）。
  // SVG 切换时由 swapSVG 清空缓存。
  function collectGeometryElements(root) {
    if (cachedGeometryElements) {
      return cachedGeometryElements;
    }

    var result = [];
    var all = root.querySelectorAll("*");
    for (var i = all.length - 1; i >= 0; i -= 1) {
      if (all[i] instanceof window.SVGGeometryElement && !isInsideDefs(all[i])) {
        result.push(all[i]);
      }
    }

    cachedGeometryElements = result;
    return result;
  }

  // 几何级命中检测（兜底路径）。
  // 当 document.elementFromPoint 因动画/pointer-events 等原因漏判时，
  // 逐个检查 SVGGeometryElement 的 fill/stroke 区域。
  function hitTestGeometry(root, clientX, clientY) {
    if (typeof window.SVGGeometryElement === "undefined") {
      return false;
    }

    var probePoint = new DOMPoint(clientX, clientY);
    var elements = collectGeometryElements(root);

    for (var i = 0; i < elements.length; i += 1) {
      var element = elements[i];
      var style = window.getComputedStyle(element);
      if (!style || style.display === "none" || style.visibility === "hidden"
          || style.pointerEvents === "none" || parseFloat(style.opacity) === 0) {
        continue;
      }

      // getScreenCTM() 返回 SVG 用户坐标 → CSS viewport 坐标的变换矩阵，
      // 取逆即可将 CSS 坐标映射回元素本地坐标。
      var matrix = element.getScreenCTM();
      if (!matrix) {
        continue;
      }

      var localPoint;
      try {
        localPoint = probePoint.matrixTransform(matrix.inverse());
      } catch (_) {
        continue;
      }

      try {
        if (element.isPointInFill(localPoint)) {
          return true;
        }
      } catch (_) {}

      try {
        if (element.isPointInStroke(localPoint)) {
          return true;
        }
      } catch (_) {}
    }

    return false;
  }

  // ── 暴露给 Swift 的 API ──

  window.HeyClawdBridge = {
    mountSVG,

    // 返回 true（命中实体）/ false（透明区域）/ null（SVG 未加载）。
    // Swift 据此切换 window.ignoresMouseEvents。
    hitTestAt: function (x, y) {
      if (!currentSVG) {
        return null;
      }

      // 快速排除：点不在 SVG 渲染区域内（含 CSS 偏移后的实际位置）。
      const bounds = currentSVG.getBoundingClientRect();
      if (x < bounds.left || y < bounds.top || x >= bounds.right || y >= bounds.bottom) {
        return false;
      }

      // 首选 DOM hit test：内联 SVG 的子元素天然参与 elementFromPoint。
      // 需要排除 opacity: 0 的元素（动画粒子、隐藏状态的部件）以免误判。
      const hit = document.elementFromPoint(x, y);
      if (hit && currentSVG.contains(hit) && hit !== currentSVG) {
        var hitStyle = window.getComputedStyle(hit);
        if (hitStyle && parseFloat(hitStyle.opacity) !== 0) {
          return true;
        }
      }

      // 兜底几何检测：覆盖 DOM hit test 因动画帧/遮挡等原因漏判的情况。
      return hitTestGeometry(currentSVG, x, y);
    },

    setMiniLeft: function (enabled) {
      container.classList.toggle("mini-left", Boolean(enabled));
    },

    postMessage
  };

  postMessage("bridge-ready");
})();
