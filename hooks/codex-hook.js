#!/usr/bin/env node
// Clawd — Codex CLI native hook (stdin JSON with hook_event_name)
// Registered in ~/.codex/hooks.json by hooks/codex-install.js.

const http = require("http");
const {
  CLAWD_SERVER_HEADER,
  CLAWD_SERVER_ID,
  PERMISSION_PATH,
  postStateToRunningServer,
  probePort,
  splitPortCandidates,
} = require("./server-config");
const { hashToolInput } = require("./lib/match-key");

const STATE_TIMEOUT_MS = 100;
const PERMISSION_TIMEOUT_MS = 305_000;

const EVENT_TO_STATE = {
  SessionStart: "idle",
  UserPromptSubmit: "thinking",
  PreToolUse: "working",
  PostToolUse: "working",
  Stop: "attention",
  PreCompact: "sweeping",
  PostCompact: "idle",
};

const TOOL_EVENTS = new Set([
  "PreToolUse",
  "PostToolUse",
  "PermissionRequest",
]);

const TERMINAL_NAMES_WIN = new Set([
  "windowsterminal.exe", "cmd.exe", "powershell.exe", "pwsh.exe",
  "code.exe", "alacritty.exe", "wezterm-gui.exe", "mintty.exe",
  "conemu64.exe", "conemu.exe", "hyper.exe", "tabby.exe",
  "antigravity.exe", "warp.exe", "iterm.exe", "ghostty.exe",
]);
const TERMINAL_NAMES_MAC = new Set([
  "terminal", "iterm2", "alacritty", "wezterm-gui", "kitty",
  "hyper", "tabby", "warp", "ghostty",
]);
const TERMINAL_NAMES_LINUX = new Set([
  "gnome-terminal", "kgx", "konsole", "xfce4-terminal", "tilix",
  "alacritty", "wezterm", "wezterm-gui", "kitty", "ghostty",
  "xterm", "lxterminal", "terminator", "tabby", "hyper", "warp",
]);

const SYSTEM_BOUNDARY_WIN = new Set(["explorer.exe", "services.exe", "winlogon.exe", "svchost.exe"]);
const SYSTEM_BOUNDARY_MAC = new Set(["launchd", "init", "systemd"]);
const SYSTEM_BOUNDARY_LINUX = new Set(["systemd", "init"]);

const EDITOR_MAP_WIN = { "code.exe": "code", "cursor.exe": "cursor" };
const EDITOR_MAP_MAC = { "code": "code", "cursor": "cursor" };
const EDITOR_MAP_LINUX = { "code": "code", "cursor": "cursor", "code-insiders": "code" };

const CODEX_NAMES_WIN = new Set(["codex.exe"]);
const CODEX_NAMES_MAC = new Set(["codex"]);
const CODEX_NAMES_LINUX = new Set(["codex"]);

let _processMetadata = null;

function codexSessionId(sessionId) {
  const raw = typeof sessionId === "string" && sessionId.length > 0 ? sessionId : "default";
  return raw.startsWith("codex:") ? raw : `codex:${raw}`;
}

function buildStatePayload(payload) {
  const hookName = payload && payload.hook_event_name;
  const state = EVENT_TO_STATE[hookName];
  if (!state) return null;

  const body = {
    state,
    session_id: codexSessionId(payload && payload.session_id),
    event: hookName,
    agent_id: "codex",
  };

  copyIfPresent(body, payload, "cwd");
  copyIfPresent(body, payload, "turn_id");
  appendProcessMetadata(body, payload);
  appendToolMetadata(body, payload, hookName);

  return body;
}

function buildPermissionPayload(payload) {
  if (!payload || payload.hook_event_name !== "PermissionRequest") return null;

  const body = {
    agent_id: "codex",
    session_id: codexSessionId(payload.session_id),
    event: "PermissionRequest",
  };

  copyIfPresent(body, payload, "cwd");
  copyIfPresent(body, payload, "turn_id");
  copyIfPresent(body, payload, "tool_name");
  copyIfPresent(body, payload, "tool_input");
  copyIfPresent(body, payload, "tool_use_id");
  appendProcessMetadata(body, payload);
  if (Object.prototype.hasOwnProperty.call(payload, "tool_input")) {
    try {
      body.tool_input_hash = hashToolInput(payload.tool_input);
    } catch {}
  }

  return body;
}

function copyIfPresent(target, source, key) {
  if (source && Object.prototype.hasOwnProperty.call(source, key)) {
    target[key] = source[key];
  }
}

function appendProcessMetadata(body, payload) {
  copyIfPresent(body, payload, "source_pid");
  copyIfPresent(body, payload, "agent_pid");
  copyIfPresent(body, payload, "codex_pid");
  copyIfPresent(body, payload, "pid_chain");
  copyIfPresent(body, payload, "editor");
  copyIfPresent(body, payload, "headless");
}

function appendToolMetadata(body, payload, hookName) {
  if (!payload || !TOOL_EVENTS.has(hookName)) return;

  copyIfPresent(body, payload, "tool_name");
  copyIfPresent(body, payload, "tool_use_id");
  if (Object.prototype.hasOwnProperty.call(payload, "tool_input")) {
    try {
      body.tool_input_hash = hashToolInput(payload.tool_input);
    } catch {}
  }
}

function terminalNameSet(platform = process.platform) {
  if (platform === "win32") return TERMINAL_NAMES_WIN;
  return platform === "linux" ? TERMINAL_NAMES_LINUX : TERMINAL_NAMES_MAC;
}

function systemBoundarySet(platform = process.platform) {
  if (platform === "win32") return SYSTEM_BOUNDARY_WIN;
  return platform === "linux" ? SYSTEM_BOUNDARY_LINUX : SYSTEM_BOUNDARY_MAC;
}

function editorMap(platform = process.platform) {
  if (platform === "win32") return EDITOR_MAP_WIN;
  return platform === "linux" ? EDITOR_MAP_LINUX : EDITOR_MAP_MAC;
}

function codexNameSet(platform = process.platform) {
  if (platform === "win32") return CODEX_NAMES_WIN;
  return platform === "linux" ? CODEX_NAMES_LINUX : CODEX_NAMES_MAC;
}

function readProcessInfo(pid, platform, execSync) {
  if (!pid || pid <= 1) return null;
  try {
    if (platform === "win32") {
      const out = execSync(
        `wmic process where "ProcessId=${pid}" get Name,ParentProcessId /format:csv`,
        { encoding: "utf8", timeout: 1500, windowsHide: true }
      );
      const lines = out.trim().split("\n").filter((line) => line.includes(","));
      if (!lines.length) return null;
      const parts = lines[lines.length - 1].split(",");
      return {
        name: (parts[1] || "").trim().toLowerCase(),
        parentPid: parseInt(parts[2], 10),
        command: "",
      };
    }

    const ppidOut = execSync(`ps -o ppid= -p ${pid}`, { encoding: "utf8", timeout: 1000 }).trim();
    const commOut = execSync(`ps -o comm= -p ${pid}`, { encoding: "utf8", timeout: 1000 }).trim();
    let commandOut = commOut;
    try {
      commandOut = execSync(`ps -o command= -p ${pid}`, { encoding: "utf8", timeout: 500 }).trim();
    } catch {}
    return {
      name: require("path").basename(commOut).toLowerCase(),
      parentPid: parseInt(ppidOut, 10),
      command: commandOut,
    };
  } catch {
    return null;
  }
}

function detectEditor(name, command, platform = process.platform) {
  const mapped = editorMap(platform)[name];
  if (mapped) return mapped;

  const fullLower = String(command || "").toLowerCase();
  if (fullLower.includes("visual studio code")) return "code";
  if (fullLower.includes("cursor.app")) return "cursor";
  return null;
}

function isCodexProcess(name, command, platform = process.platform) {
  if (codexNameSet(platform).has(name)) return true;

  const fullLower = String(command || "").toLowerCase();
  return fullLower.includes("@openai/codex") ||
    fullLower.includes("/codex-darwin-") ||
    fullLower.includes("\\codex-") ||
    /\bcodex(\.exe)?\b/.test(fullLower);
}

function isCodexAppProcess(command) {
  const fullLower = String(command || "").toLowerCase();
  return fullLower.includes(".app/contents/macos/") &&
    (fullLower.includes("/codex.app/") || fullLower.endsWith("/codex"));
}

function isHeadlessCodexCommand(command) {
  const text = String(command || "");
  return /\bcodex\s+(exec|app-server)\b/.test(text) ||
    /\s(exec|app-server)(\s|$)/.test(text);
}

function getCodexProcessMetadata(options = {}) {
  if (_processMetadata && !options.execSync && !options.startPid && !options.platform) {
    return _processMetadata;
  }

  const platform = options.platform || process.platform;
  const execSync = options.execSync || require("child_process").execSync;
  const terminalNames = terminalNameSet(platform);
  const systemBoundary = systemBoundarySet(platform);
  let pid = options.startPid || process.ppid;
  let terminalPid = null;
  let codexPid = null;
  let codexCommand = "";
  let codexAppPid = null;
  let detectedEditor = null;
  const pidChain = [];

  for (let i = 0; i < 8; i++) {
    const info = readProcessInfo(pid, platform, execSync);
    if (!info) break;

    pidChain.push(pid);
    if (!detectedEditor) detectedEditor = detectEditor(info.name, info.command, platform);
    if (!codexPid && isCodexProcess(info.name, info.command, platform)) {
      codexPid = pid;
      codexCommand = info.command || "";
    }
    if (!codexAppPid && isCodexAppProcess(info.command)) {
      codexAppPid = pid;
    }
    if (systemBoundary.has(info.name)) break;
    if (terminalNames.has(info.name)) terminalPid = pid;
    if (!info.parentPid || info.parentPid === pid || info.parentPid <= 1) break;
    pid = info.parentPid;
  }

  const metadata = {
    sourcePid: terminalPid || codexAppPid || null,
    codexPid: codexPid || null,
    pidChain,
    editor: detectedEditor,
    headless: codexPid ? isHeadlessCodexCommand(codexCommand) : false,
  };

  if (!options.execSync && !options.startPid && !options.platform) {
    _processMetadata = metadata;
  }
  return metadata;
}

function attachCodexProcessMetadata(payload, metadata = getCodexProcessMetadata()) {
  if (!payload || process.env.CLAWD_REMOTE) return payload || {};
  const next = { ...payload };
  if (metadata.sourcePid && !Object.prototype.hasOwnProperty.call(next, "source_pid")) {
    next.source_pid = metadata.sourcePid;
  }
  if (metadata.codexPid) {
    if (!Object.prototype.hasOwnProperty.call(next, "agent_pid")) next.agent_pid = metadata.codexPid;
    if (!Object.prototype.hasOwnProperty.call(next, "codex_pid")) next.codex_pid = metadata.codexPid;
  }
  if (metadata.pidChain && metadata.pidChain.length && !Object.prototype.hasOwnProperty.call(next, "pid_chain")) {
    next.pid_chain = metadata.pidChain;
  }
  if (metadata.editor && !Object.prototype.hasOwnProperty.call(next, "editor")) {
    next.editor = metadata.editor;
  }
  if (metadata.headless && !Object.prototype.hasOwnProperty.call(next, "headless")) {
    next.headless = true;
  }
  return next;
}

function parsePayload(raw) {
  try {
    const text = Buffer.isBuffer(raw) ? raw.toString() : String(raw || "");
    return text.trim() ? JSON.parse(text) : {};
  } catch {
    return {};
  }
}

function writeDefaultOutput(writeStdout) {
  writeStdout("{}\n");
}

function writeHookOutput(writeStdout, body) {
  const text = typeof body === "string" && body.trim() ? body.trim() : "{}";
  try {
    JSON.parse(text);
    writeStdout(`${text}\n`);
  } catch {
    writeDefaultOutput(writeStdout);
  }
}

function shouldSkipPermissionRequest(payload) {
  return payload && (
    payload.permission_mode === "bypassPermissions" ||
    payload.permission_mode === "dontAsk"
  );
}

function runPayload(payload, options = {}, done = () => {}) {
  const writeStdout = options.writeStdout || ((text) => process.stdout.write(text));
  if (payload && payload.hook_event_name === "PermissionRequest") {
    runPermissionPayload(payload, options, done);
    return;
  }

  const body = buildStatePayload(payload);
  if (!body) {
    writeDefaultOutput(writeStdout);
    done(false, null);
    return;
  }

  const data = JSON.stringify(body);
  if (options.dryRun) {
    writeStdout(data);
    done(true, null);
    return;
  }

  const postState = options.postStateToRunningServer || postStateToRunningServer;
  postState(data, { timeoutMs: STATE_TIMEOUT_MS }, (ok, port) => {
    writeDefaultOutput(writeStdout);
    done(ok, port);
  });
}

function runPermissionPayload(payload, options = {}, done = () => {}) {
  const writeStdout = options.writeStdout || ((text) => process.stdout.write(text));
  if (shouldSkipPermissionRequest(payload)) {
    writeDefaultOutput(writeStdout);
    done(false, null);
    return;
  }

  const body = buildPermissionPayload(payload);
  if (!body) {
    writeDefaultOutput(writeStdout);
    done(false, null);
    return;
  }

  const data = JSON.stringify(body);
  if (options.dryRun) {
    writeStdout(data);
    done(true, null);
    return;
  }

  const postPermission = options.postPermissionToRunningServer || postPermissionToRunningServer;
  postPermission(data, { timeoutMs: PERMISSION_TIMEOUT_MS }, (ok, port, responseBody) => {
    writeHookOutput(writeStdout, ok ? responseBody : "{}");
    done(ok, port);
  });
}

function postPermissionToRunningServer(body, options, callback) {
  const timeoutMs = options && options.timeoutMs ? options.timeoutMs : PERMISSION_TIMEOUT_MS;
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  const { direct, fallback } = splitPortCandidates(options && options.preferredPort, options);
  const probe = options && options.probePort ? options.probePort : probePort;
  const post = options && options.postPermissionToPort ? options.postPermissionToPort : postPermissionToPort;
  let directIndex = 0;
  let fallbackIndex = 0;

  const tryFallback = () => {
    if (fallbackIndex >= fallback.length) {
      callback(false, null, null);
      return;
    }

    const port = fallback[fallbackIndex++];
    probe(port, STATE_TIMEOUT_MS, (ok) => {
      if (!ok) {
        tryFallback();
        return;
      }
      post(port, payload, timeoutMs, (posted, confirmedPort, responseBody) => {
        if (posted) {
          callback(true, confirmedPort, responseBody);
          return;
        }
        tryFallback();
      }, options);
    }, options);
  };

  const tryDirect = () => {
    if (directIndex >= direct.length) {
      tryFallback();
      return;
    }

    const port = direct[directIndex++];
    post(port, payload, timeoutMs, (posted, confirmedPort, responseBody) => {
      if (posted) {
        callback(true, confirmedPort, responseBody);
        return;
      }
      tryDirect();
    }, options);
  };

  tryDirect();
}

function postPermissionToPort(port, payload, timeoutMs, callback, options = {}) {
  const httpRequest = options.httpRequest || http.request;
  let finished = false;
  const finish = (ok, responseBody = null) => {
    if (finished) return;
    finished = true;
    callback(ok, port, responseBody);
  };

  const req = httpRequest(
    {
      hostname: "127.0.0.1",
      port,
      path: PERMISSION_PATH,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(payload),
      },
      timeout: timeoutMs,
    },
    (res) => {
      let responseBody = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => {
        if (responseBody.length < 1_048_576) responseBody += chunk;
      });
      res.on("end", () => {
        const clawdHeader = res.headers && res.headers[CLAWD_SERVER_HEADER];
        const isClawd = Array.isArray(clawdHeader)
          ? clawdHeader.includes(CLAWD_SERVER_ID)
          : clawdHeader === CLAWD_SERVER_ID;
        const statusOk = res.statusCode >= 200 && res.statusCode < 300;
        finish(statusOk && isClawd, responseBody);
      });
    }
  );

  req.on("error", () => finish(false));
  req.on("timeout", () => {
    req.destroy();
    finish(false);
  });
  req.end(payload);
}

function main() {
  const chunks = [];
  let ran = false;
  let stdinTimer = null;

  const finishOnce = (payload) => {
    if (ran) return;
    ran = true;
    if (stdinTimer) clearTimeout(stdinTimer);
    runPayload(
      attachCodexProcessMetadata(payload),
      { dryRun: process.env.CLAWD_DRY_RUN === "1" },
      () => process.exit(0)
    );
  };

  process.stdin.on("data", (chunk) => chunks.push(chunk));
  process.stdin.on("end", () => {
    finishOnce(parsePayload(Buffer.concat(chunks)));
  });

  stdinTimer = setTimeout(() => finishOnce({}), 400);
}

module.exports = {
  EVENT_TO_STATE,
  PERMISSION_TIMEOUT_MS,
  STATE_TIMEOUT_MS,
  attachCodexProcessMetadata,
  buildPermissionPayload,
  buildStatePayload,
  codexSessionId,
  getCodexProcessMetadata,
  parsePayload,
  postPermissionToPort,
  postPermissionToRunningServer,
  runPayload,
  shouldSkipPermissionRequest,
};

if (require.main === module) {
  main();
}
