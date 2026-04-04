(function () {
  const container = document.getElementById("pet-container");
  let currentObject = document.getElementById("clawd");
  let pendingObject = null;

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
      if (!currentObject) {
        return false;
      }

      const bounds = currentObject.getBoundingClientRect();
      const localX = Math.floor(x - bounds.left);
      const localY = Math.floor(y - bounds.top);

      if (localX < 0 || localY < 0 || localX >= bounds.width || localY >= bounds.height) {
        return false;
      }

      const svgDocument = currentObject.contentDocument;
      const root = svgDocument && svgDocument.documentElement;
      if (!svgDocument || !root || typeof svgDocument.elementFromPoint !== "function") {
        return false;
      }

      // 直接查询 live SVG DOM，动画中的瞬时姿态也会参与命中。
      const hit = svgDocument.elementFromPoint(localX, localY);
      return Boolean(hit && hit !== root);
    },
    setMiniLeft: function (enabled) {
      container.classList.toggle("mini-left", Boolean(enabled));
    },
    postMessage
  };

  postMessage("bridge-ready");
})();
