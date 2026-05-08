#!/usr/bin/env node
// Clawd — Codex CLI native hook (stdin JSON with hook_event_name)
// Registered in ~/.codex/hooks.json by hooks/codex-install.js.

const { postStateToRunningServer } = require("./server-config");
const { hashToolInput } = require("./lib/match-key");

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

function runPayload(payload, options = {}, done = () => {}) {
  const writeStdout = options.writeStdout || ((text) => process.stdout.write(text));
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
  postState(data, { timeoutMs: 100 }, (ok, port) => {
    writeDefaultOutput(writeStdout);
    done(ok, port);
  });
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
  buildStatePayload,
  codexSessionId,
  parsePayload,
  runPayload,
};

if (require.main === module) {
  main();
}
