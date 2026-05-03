const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const { hashToolInput } = require("../lib/match-key");

function runHook(event, payload, extraEnv = {}) {
  const env = {
    ...process.env,
    CLAWD_DRY_RUN: "1",
    CLAWD_REMOTE: "1",
  };
  Object.assign(env, extraEnv);

  const result = spawnSync(
    process.execPath,
    [path.join(__dirname, "../clawd-hook.js"), event],
    {
      cwd: __dirname,
      env,
      input: JSON.stringify(payload),
      encoding: "utf8",
    }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.notEqual(result.stdout, "");
  return JSON.parse(result.stdout);
}

test("tool events include tool metadata by default", () => {
  const payload = {
    session_id: "session-1",
    cwd: "/tmp/project",
    tool_name: "Bash",
    tool_input: { command: "ls" },
    tool_use_id: "toolu_1",
  };

  const body = runHook("PreToolUse", payload);

  assert.equal(body.tool_name, "Bash");
  assert.equal(body.tool_input_hash, hashToolInput(payload.tool_input));
  assert.equal(body.tool_use_id, "toolu_1");
});

test("tool metadata is absent for non-tool events", () => {
  const body = runHook("SessionStart", {
    session_id: "session-3",
    tool_name: "Bash",
    tool_input: { command: "ls" },
  });

  assert.equal(Object.prototype.hasOwnProperty.call(body, "tool_input_hash"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(body, "tool_name"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(body, "tool_use_id"), false);
});

test("tool events without tool input remain valid state payloads", () => {
  const body = runHook("PreToolUse", {
    session_id: "session-4",
    tool_name: "Bash",
    tool_use_id: "toolu_4",
  });

  assert.equal(body.state, "working");
  assert.equal(body.event, "PreToolUse");
  assert.equal(body.tool_name, "Bash");
  assert.equal(body.tool_use_id, "toolu_4");
  assert.equal(Object.prototype.hasOwnProperty.call(body, "tool_input_hash"), false);
});

test("PostToolBatch emits compact metadata for each tool call", () => {
  const payload = {
    session_id: "session-5",
    cwd: "/tmp/project",
    tool_calls: [
      {
        tool_name: "Bash",
        tool_input: { command: "date" },
        tool_use_id: "toolu_5",
        tool_response: "large response omitted from state payload",
      },
      {
        tool_name: "Read",
        tool_input: { file_path: "README.md" },
        tool_use_id: "toolu_6",
      },
    ],
  };

  const body = runHook("PostToolBatch", payload);

  assert.equal(body.state, "working");
  assert.equal(body.event, "PostToolBatch");
  assert.deepEqual(body.tool_calls, [
    {
      tool_name: "Bash",
      tool_use_id: "toolu_5",
      tool_input_hash: hashToolInput(payload.tool_calls[0].tool_input),
    },
    {
      tool_name: "Read",
      tool_use_id: "toolu_6",
      tool_input_hash: hashToolInput(payload.tool_calls[1].tool_input),
    },
  ]);
  assert.equal(Object.prototype.hasOwnProperty.call(body.tool_calls[0], "tool_response"), false);
});
