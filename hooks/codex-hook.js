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
    runPayload(payload, { dryRun: process.env.CLAWD_DRY_RUN === "1" }, () => process.exit(0));
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
  buildPermissionPayload,
  buildStatePayload,
  codexSessionId,
  parsePayload,
  postPermissionToPort,
  postPermissionToRunningServer,
  runPayload,
  shouldSkipPermissionRequest,
};

if (require.main === module) {
  main();
}
