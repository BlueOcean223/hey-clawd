const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const {
  EVENT_TO_STATE,
  buildStatePayload,
  codexSessionId,
  parsePayload,
  runPayload,
} = require("../codex-hook");
const { hashToolInput } = require("../lib/match-key");

const STATE_CASES = {
  SessionStart: "idle",
  UserPromptSubmit: "thinking",
  PreToolUse: "working",
  PostToolUse: "working",
  Stop: "attention",
  PreCompact: "sweeping",
  PostCompact: "idle",
};

test("Codex hook maps known state events to /state payloads", () => {
  assert.deepEqual(EVENT_TO_STATE, STATE_CASES);

  for (const [event, state] of Object.entries(STATE_CASES)) {
    const body = buildStatePayload({
      hook_event_name: event,
      session_id: "session-1",
      cwd: "/repo",
      turn_id: "turn-1",
    });

    assert.equal(body.state, state);
    assert.equal(body.event, event);
    assert.equal(body.session_id, "codex:session-1");
    assert.equal(body.agent_id, "codex");
    assert.equal(body.cwd, "/repo");
    assert.equal(body.turn_id, "turn-1");
  }
});

test("Codex hook preserves existing codex session prefix", () => {
  assert.equal(codexSessionId("session-2"), "codex:session-2");
  assert.equal(codexSessionId("codex:session-2"), "codex:session-2");
  assert.equal(codexSessionId(""), "codex:default");
});

test("Codex hook attaches stable tool metadata for tool events", () => {
  const toolInput = { command: "ls", options: { all: true } };

  for (const event of ["PreToolUse", "PostToolUse"]) {
    const body = buildStatePayload({
      hook_event_name: event,
      session_id: "session-tool",
      tool_name: "shell",
      tool_input: toolInput,
      tool_use_id: "tool-1",
    });

    assert.equal(body.tool_name, "shell");
    assert.equal(body.tool_use_id, "tool-1");
    assert.equal(body.tool_input_hash, hashToolInput(toolInput));
  }
});

test("Codex hook skips tool hash when tool_input is absent", () => {
  const body = buildStatePayload({
    hook_event_name: "PreToolUse",
    session_id: "session-tool",
    tool_name: "shell",
    tool_use_id: "tool-2",
  });

  assert.equal(body.tool_name, "shell");
  assert.equal(body.tool_use_id, "tool-2");
  assert.equal(Object.prototype.hasOwnProperty.call(body, "tool_input_hash"), false);
});

test("Codex hook ignores unknown events without posting state", () => {
  let posted = false;
  let stdout = "";
  let doneResult = null;

  runPayload(
    { hook_event_name: "UnknownEvent", session_id: "session-unknown" },
    {
      writeStdout: (text) => { stdout += text; },
      postStateToRunningServer: () => { posted = true; },
    },
    (ok, port) => { doneResult = { ok, port }; }
  );

  assert.equal(posted, false);
  assert.equal(stdout, "{}\n");
  assert.deepEqual(doneResult, { ok: false, port: null });
});

test("Codex hook posts state with 100ms timeout and fail-opens stdout", () => {
  let postedBody = null;
  let postedOptions = null;
  let stdout = "";
  let doneResult = null;

  runPayload(
    { hook_event_name: "SessionStart", session_id: "session-post" },
    {
      writeStdout: (text) => { stdout += text; },
      postStateToRunningServer: (data, options, callback) => {
        postedBody = JSON.parse(data);
        postedOptions = options;
        callback(false, null);
      },
    },
    (ok, port) => { doneResult = { ok, port }; }
  );

  assert.equal(postedBody.state, "idle");
  assert.equal(postedBody.session_id, "codex:session-post");
  assert.equal(postedOptions.timeoutMs, 100);
  assert.equal(stdout, "{}\n");
  assert.deepEqual(doneResult, { ok: false, port: null });
});

test("Codex hook process reads hook_event_name from stdin instead of argv", () => {
  const result = spawnSync(
    process.execPath,
    [path.join(__dirname, "../codex-hook.js"), "Stop"],
    {
      cwd: __dirname,
      env: {
        ...process.env,
        CLAWD_DRY_RUN: "1",
      },
      input: JSON.stringify({
        hook_event_name: "SessionStart",
        session_id: "process-session",
      }),
      encoding: "utf8",
      timeout: 2000,
    }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  const body = JSON.parse(result.stdout);
  assert.equal(body.event, "SessionStart");
  assert.equal(body.state, "idle");
  assert.equal(body.session_id, "codex:process-session");
});

test("Codex hook process handles malformed stdin as fail-open", () => {
  const result = spawnSync(
    process.execPath,
    [path.join(__dirname, "../codex-hook.js")],
    {
      cwd: __dirname,
      input: "{ invalid json",
      encoding: "utf8",
      timeout: 1000,
    }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(result.stdout, "{}\n");
  assert.deepEqual(parsePayload("{ invalid json"), {});
});
