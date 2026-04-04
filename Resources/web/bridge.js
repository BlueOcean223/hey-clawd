(function () {
  const container = document.getElementById("pet-container");
  let currentObject = document.getElementById("clawd");
  let pendingObject = null;
  // 当前 SVG 会被画到离屏 canvas 上，Swift 侧再按 alpha 判断是不是透明像素。
  let hitCanvas = null;
  let hitContext = null;
  let hitImageUrl = null;

  function postMessage(type, payload = {}) {
    const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge;
    if (!bridge) {
      return;
    }

    bridge.postMessage({ type, ...payload });
  }

  function releaseObject(objectEl) {
    if (!objectEl) {
      return;
    }

    try {
      objectEl.data = "";
    } catch (_) {}

    objectEl.remove();
  }

  function resetHitMap() {
    if (hitImageUrl) {
      URL.revokeObjectURL(hitImageUrl);
      hitImageUrl = null;
    }

    hitCanvas = null;
    hitContext = null;
  }

  function buildHitMap(objectEl) {
    resetHitMap();

    const svgDocument = objectEl && objectEl.contentDocument;
    const svgRoot = svgDocument && svgDocument.documentElement;
    const bounds = objectEl && objectEl.getBoundingClientRect();
    if (!svgRoot || !bounds || !bounds.width || !bounds.height) {
      return;
    }

    const svgMarkup = new XMLSerializer().serializeToString(svgRoot);
    const blob = new Blob([svgMarkup], { type: "image/svg+xml;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const image = new Image();

    image.onload = function () {
      // 命中只关心当前屏幕上的像素分布，所以直接按 object 实际显示尺寸栅格化。
      const width = Math.max(1, Math.round(bounds.width));
      const height = Math.max(1, Math.round(bounds.height));
      hitCanvas = document.createElement("canvas");
      hitCanvas.width = width;
      hitCanvas.height = height;
      hitContext = hitCanvas.getContext("2d", { willReadFrequently: true });

      if (hitContext) {
        hitContext.clearRect(0, 0, width, height);
        hitContext.drawImage(image, 0, 0, width, height);
      }

      URL.revokeObjectURL(url);
      if (hitImageUrl === url) {
        hitImageUrl = null;
      }
      postMessage("hitmap-ready", { width, height });
    };

    image.onerror = function () {
      URL.revokeObjectURL(url);
      if (hitImageUrl === url) {
        hitImageUrl = null;
      }
      postMessage("hitmap-error");
    };

    hitImageUrl = url;
    image.src = url;
  }

  function svgURL(filename) {
    return `../svg/${filename}`;
  }

  function swapObject(nextObject, filename) {
    if (pendingObject !== nextObject) {
      return;
    }

    nextObject.style.transition = "none";
    nextObject.style.opacity = "1";
    nextObject.dataset.filename = filename;

    Array.from(container.querySelectorAll("object")).forEach((objectEl) => {
      if (objectEl !== nextObject) {
        releaseObject(objectEl);
      }
    });

    pendingObject = null;
    currentObject = nextObject;
    buildHitMap(nextObject);
    postMessage("svg-loaded", { filename });
  }

  function loadSVG(filename) {
    if (!filename) {
      return;
    }

    if (pendingObject) {
      releaseObject(pendingObject);
      pendingObject = null;
    }

    if (currentObject && currentObject.dataset.filename === filename) {
      return;
    }

    const nextObject = document.createElement("object");
    nextObject.id = "clawd";
    nextObject.type = "image/svg+xml";
    nextObject.style.opacity = "0";
    nextObject.style.transition = "opacity 120ms linear";

    nextObject.addEventListener("load", function () {
      swapObject(nextObject, filename);
    }, { once: true });

    nextObject.addEventListener("error", function () {
      postMessage("svg-error", { filename });
    }, { once: true });

    nextObject.data = svgURL(filename);
    container.appendChild(nextObject);
    pendingObject = nextObject;

    window.setTimeout(function () {
      if (pendingObject !== nextObject) {
        return;
      }

      swapObject(nextObject, filename);
      postMessage("svg-timeout", { filename });
    }, 3000);
  }

  window.HeyClawdBridge = {
    loadSVG,
    hitTestAt: function (x, y) {
      if (!currentObject || !hitContext || !hitCanvas) {
        return false;
      }

      // Swift 传进来的是 web view 局部坐标，这里换算成 object 内部像素坐标。
      const bounds = currentObject.getBoundingClientRect();
      const localX = Math.floor(x - bounds.left);
      const localY = Math.floor(y - bounds.top);

      if (localX < 0 || localY < 0 || localX >= hitCanvas.width || localY >= hitCanvas.height) {
        return false;
      }

      const alpha = hitContext.getImageData(localX, localY, 1, 1).data[3];
      return alpha > 0;
    },
    setMiniLeft: function (enabled) {
      container.classList.toggle("mini-left", Boolean(enabled));
    },
    postMessage
  };

  postMessage("bridge-ready");
})();
