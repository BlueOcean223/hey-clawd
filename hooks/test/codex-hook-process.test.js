const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const {
  EVENT_TO_STATE,
  PERMISSION_TIMEOUT_MS,
  attachCodexProcessMetadata,
  buildPermissionPayload,
  buildStatePayload,
  codexSessionId,
  getCodexProcessMetadata,
  parsePayload,
  runPayload,
  shouldSkipPermissionRequest,
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

test("Codex hook preserves process metadata for focus and lifecycle", () => {
  const body = buildStatePayload({
    hook_event_name: "SessionStart",
    session_id: "session-focus",
    source_pid: 123,
    agent_pid: 456,
    codex_pid: 456,
    pid_chain: [456, 200, 123],
    editor: "cursor",
    headless: true,
  });

  assert.equal(body.source_pid, 123);
  assert.equal(body.agent_pid, 456);
  assert.equal(body.codex_pid, 456);
  assert.deepEqual(body.pid_chain, [456, 200, 123]);
  assert.equal(body.editor, "cursor");
  assert.equal(body.headless, true);
});

test("Codex hook resolves CLI focus to the terminal ancestor", () => {
  const metadata = getCodexProcessMetadata({
    platform: "darwin",
    startPid: 10,
    execSync: fakePs({
      10: {
        ppid: 11,
        comm: "/Users/me/.nvm/versions/node/vendor/codex/codex",
        command: "/Users/me/.nvm/versions/node/vendor/codex/codex",
      },
      11: { ppid: 12, comm: "/bin/zsh", command: "-/bin/zsh" },
      12: {
        ppid: 1,
        comm: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
      },
    }),
  });

  assert.equal(metadata.sourcePid, 12);
  assert.equal(metadata.codexPid, 10);
  assert.deepEqual(metadata.pidChain, [10, 11, 12]);
  assert.equal(metadata.headless, false);

  const body = attachCodexProcessMetadata({ hook_event_name: "SessionStart" }, metadata);
  assert.equal(body.source_pid, 12);
  assert.equal(body.agent_pid, 10);
  assert.equal(body.codex_pid, 10);
  assert.deepEqual(body.pid_chain, [10, 11, 12]);
});

test("Codex hook resolves app focus when no terminal ancestor exists", () => {
  const metadata = getCodexProcessMetadata({
    platform: "darwin",
    startPid: 20,
    execSync: fakePs({
      20: {
        ppid: 1,
        comm: "/Applications/Codex.app/Contents/MacOS/Codex",
        command: "/Applications/Codex.app/Contents/MacOS/Codex",
      },
    }),
  });

  assert.equal(metadata.sourcePid, 20);
  assert.equal(metadata.codexPid, 20);
  assert.deepEqual(metadata.pidChain, [20]);
});

test("Codex hook marks noninteractive codex exec sessions headless", () => {
  const metadata = getCodexProcessMetadata({
    platform: "darwin",
    startPid: 30,
    execSync: fakePs({
      30: {
        ppid: 31,
        comm: "/Users/me/.nvm/versions/node/vendor/codex/codex",
        command: "/Users/me/.nvm/versions/node/vendor/codex/codex exec run-tests",
      },
      31: { ppid: 32, comm: "/bin/zsh", command: "-/bin/zsh" },
      32: {
        ppid: 1,
        comm: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        command: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
      },
    }),
  });

  assert.equal(metadata.sourcePid, 32);
  assert.equal(metadata.codexPid, 30);
  assert.equal(metadata.headless, true);
  const body = attachCodexProcessMetadata({ hook_event_name: "SessionStart" }, metadata);
  assert.equal(body.headless, true);
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

test("Codex hook builds PermissionRequest payload without permission suggestions", () => {
  const toolInput = { command: "cat package.json" };
  const body = buildPermissionPayload({
    hook_event_name: "PermissionRequest",
    session_id: "permission-session",
    cwd: "/repo",
    turn_id: "turn-permission",
    tool_name: "shell",
    tool_input: toolInput,
    tool_use_id: "tool-permission",
    permission_suggestions: [{ type: "addRules" }],
  });

  assert.equal(body.agent_id, "codex");
  assert.equal(body.session_id, "codex:permission-session");
  assert.equal(body.event, "PermissionRequest");
  assert.equal(body.cwd, "/repo");
  assert.equal(body.turn_id, "turn-permission");
  assert.equal(body.tool_name, "shell");
  assert.deepEqual(body.tool_input, toolInput);
  assert.equal(body.tool_use_id, "tool-permission");
  assert.equal(body.tool_input_hash, hashToolInput(toolInput));
  assert.equal(Object.prototype.hasOwnProperty.call(body, "permission_suggestions"), false);
});

test("Codex PermissionRequest allow returns Codex-safe allow output", () => {
  const allowBody = JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" },
    },
  });
  let postedPayload = null;
  let stdout = "";

  runPayload(
    {
      hook_event_name: "PermissionRequest",
      session_id: "allow-session",
      tool_name: "shell",
      tool_input: { command: "date" },
    },
    {
      writeStdout: (text) => { stdout += text; },
      postPermissionToRunningServer: (data, options, callback) => {
        postedPayload = JSON.parse(data);
        assert.equal(options.timeoutMs, PERMISSION_TIMEOUT_MS);
        callback(true, 23333, allowBody);
      },
    }
  );

  assert.equal(postedPayload.agent_id, "codex");
  assert.equal(postedPayload.session_id, "codex:allow-session");
  assert.equal(stdout, `${allowBody}\n`);
  assert.equal(stdout.includes("updatedPermissions"), false);
});

test("Codex PermissionRequest deny returns Codex-safe deny output", () => {
  const denyBody = JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: {
        behavior: "deny",
        message: "Denied by user.",
      },
    },
  });
  let stdout = "";

  runPayload(
    {
      hook_event_name: "PermissionRequest",
      session_id: "deny-session",
      tool_name: "shell",
      tool_input: { command: "rm file" },
    },
    {
      writeStdout: (text) => { stdout += text; },
      postPermissionToRunningServer: (_data, _options, callback) => {
        callback(true, 23333, denyBody);
      },
    }
  );

  const output = JSON.parse(stdout);
  assert.equal(output.hookSpecificOutput.decision.behavior, "deny");
  assert.equal(output.hookSpecificOutput.decision.message, "Denied by user.");
});

test("Codex PermissionRequest undecided and unavailable paths fail open", () => {
  for (const response of [
    { ok: true, body: "{}" },
    { ok: false, body: null },
    { ok: true, body: "not json" },
  ]) {
    let stdout = "";
    runPayload(
      {
        hook_event_name: "PermissionRequest",
        session_id: "undecided-session",
        tool_name: "shell",
        tool_input: { command: "pwd" },
      },
      {
        writeStdout: (text) => { stdout += text; },
        postPermissionToRunningServer: (_data, _options, callback) => {
          callback(response.ok, response.ok ? 23333 : null, response.body);
        },
      }
    );

    assert.equal(stdout, "{}\n");
  }
});

test("Codex PermissionRequest bypass modes do not call /permission", () => {
  for (const permissionMode of ["bypassPermissions", "dontAsk"]) {
    let posted = false;
    let stdout = "";

    assert.equal(shouldSkipPermissionRequest({ permission_mode: permissionMode }), true);
    runPayload(
      {
        hook_event_name: "PermissionRequest",
        session_id: "skip-session",
        permission_mode: permissionMode,
        tool_name: "shell",
        tool_input: { command: "whoami" },
      },
      {
        writeStdout: (text) => { stdout += text; },
        postPermissionToRunningServer: () => { posted = true; },
      }
    );

    assert.equal(posted, false);
    assert.equal(stdout, "{}\n");
  }
});

function fakePs(processes) {
  return (command) => {
    const match = String(command).match(/-p\s+(\d+)/);
    assert.ok(match, `missing pid in command: ${command}`);
    const pid = Number(match[1]);
    const proc = processes[pid];
    if (!proc) throw new Error(`unknown pid ${pid}`);

    if (/ps -o ppid=/.test(command)) return String(proc.ppid);
    if (/ps -o comm=/.test(command)) return proc.comm;
    if (/ps -o command=/.test(command)) return proc.command || proc.comm;
    throw new Error(`unexpected command: ${command}`);
  };
}
