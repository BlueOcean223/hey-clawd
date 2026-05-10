const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  registerCodexHooks,
  unregisterCodexHooks,
  unregisterCodexPermissionHook,
  CODEX_HOOK_EVENTS,
  CODEX_STATE_HOOK_EVENTS,
  CODEX_PERMISSION_HOOK_EVENT,
} = require("../codex-install");

const EXPECTED_STATUS_MESSAGES = {
  SessionStart: "Clawd: session started",
  UserPromptSubmit: "Clawd: thinking",
  PreToolUse: "Clawd: working",
  PermissionRequest: "Clawd: waiting for permission",
  PostToolUse: "Clawd: working",
  Stop: "Clawd: attention",
  PreCompact: "Clawd: compacting",
  PostCompact: "Clawd: idle",
};

function makeTempCodexDir(prefix) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`));
  const codexDir = path.join(root, ".codex");
  fs.mkdirSync(codexDir, { recursive: true });
  return { root, codexDir, hooksPath: path.join(codexDir, "hooks.json") };
}

function writeHooks(hooksPath, settings) {
  fs.mkdirSync(path.dirname(hooksPath), { recursive: true });
  fs.writeFileSync(hooksPath, JSON.stringify(settings, null, 2), "utf8");
}

function writeRaw(hooksPath, content) {
  fs.mkdirSync(path.dirname(hooksPath), { recursive: true });
  fs.writeFileSync(hooksPath, content, "utf8");
}

function readHooks(hooksPath) {
  return JSON.parse(fs.readFileSync(hooksPath, "utf8"));
}

function expectedCodexCommand(nodeBin = "/usr/bin/node") {
  const hookPath = path.resolve(__dirname, "../codex-hook.js").replace(/\\/g, "/");
  return `"${nodeBin}" "${hookPath}"`;
}

function collectCommandHooks(entries) {
  return entries.flatMap((entry) => {
    if (!entry || typeof entry !== "object") return [];
    const commands = [];
    if (typeof entry.command === "string") commands.push(entry.command);
    if (Array.isArray(entry.hooks)) {
      for (const hook of entry.hooks) {
        if (hook && typeof hook.command === "string") commands.push(hook.command);
      }
    }
    return commands;
  });
}

test("registerCodexHooks skips when ~/.codex is missing", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-missing-"));
  const codexDir = path.join(root, ".codex");
  const hooksPath = path.join(codexDir, "hooks.json");

  const result = registerCodexHooks({
    codexDir,
    hooksPath,
    silent: true,
    nodeBin: "/usr/bin/node",
  });

  assert.deepEqual(result, { added: 0, skipped: 0, updated: 0 });
  assert.equal(fs.existsSync(codexDir), false);
  assert.equal(fs.existsSync(hooksPath), false);
});

test("registerCodexHooks writes state hook events without touching config.toml", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-install");
  const configPath = path.join(codexDir, "config.toml");
  fs.writeFileSync(configPath, "hooks = false\n", "utf8");

  const result = registerCodexHooks({
    codexDir,
    hooksPath,
    silent: true,
    nodeBin: "/usr/bin/node",
  });
  const settings = readHooks(hooksPath);

  assert.equal(result.added, CODEX_STATE_HOOK_EVENTS.length);
  assert.equal(result.updated, 0);
  assert.equal(result.skipped, 0);
  assert.equal(fs.readFileSync(configPath, "utf8"), "hooks = false\n");
  assert.equal(Object.prototype.hasOwnProperty.call(settings.hooks, CODEX_PERMISSION_HOOK_EVENT), false);

  for (const event of CODEX_STATE_HOOK_EVENTS) {
    assert.equal(Array.isArray(settings.hooks[event]), true);
    assert.equal(settings.hooks[event].length, 1);
    assert.equal(settings.hooks[event][0].matcher, "*");
    assert.deepEqual(settings.hooks[event][0].hooks, [
      {
        type: "command",
        command: expectedCodexCommand(),
        timeout: event === "PermissionRequest" ? 600 : 10,
        statusMessage: EXPECTED_STATUS_MESSAGES[event],
      },
    ]);
  }
});

test("registerCodexHooks is idempotent", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-idempotent");

  registerCodexHooks({ codexDir, hooksPath, silent: true, nodeBin: "/usr/bin/node" });
  const before = fs.readFileSync(hooksPath, "utf8");
  const rerun = registerCodexHooks({ codexDir, hooksPath, silent: true, nodeBin: "/usr/bin/node" });
  const after = fs.readFileSync(hooksPath, "utf8");

  assert.deepEqual(rerun, { added: 0, skipped: CODEX_STATE_HOOK_EVENTS.length, updated: 0 });
  assert.equal(after, before);
});

test("registerCodexHooks preserves user hooks and top-level settings", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-append");
  writeHooks(hooksPath, {
    hooks: {
      PreToolUse: [
        {
          matcher: "Bash",
          hooks: [
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/user-hook.js\"", timeout: 20 },
          ],
        },
      ],
      Stop: {
        matcher: "keep",
        hooks: [
          { type: "command", command: "\"/usr/bin/node\" \"/tmp/legacy-user.js\"" },
        ],
      },
    },
    userSetting: true,
  });

  const result = registerCodexHooks({
    codexDir,
    hooksPath,
    silent: true,
    nodeBin: "/usr/bin/node",
  });
  const settings = readHooks(hooksPath);

  assert.equal(result.added, CODEX_STATE_HOOK_EVENTS.length);
  assert.equal(settings.userSetting, true);
  assert.equal(
    collectCommandHooks(settings.hooks.PreToolUse).includes("\"/usr/bin/node\" \"/tmp/user-hook.js\""),
    true
  );
  assert.equal(
    collectCommandHooks(settings.hooks.Stop).includes("\"/usr/bin/node\" \"/tmp/legacy-user.js\""),
    true
  );
  assert.equal(collectCommandHooks(settings.hooks.PreToolUse).includes(expectedCodexCommand()), true);
  assert.equal(collectCommandHooks(settings.hooks.Stop).includes(expectedCodexCommand()), true);
  assert.equal(Object.prototype.hasOwnProperty.call(settings.hooks, CODEX_PERMISSION_HOOK_EVENT), false);
});

test("registerCodexHooks removes stale permission hook by default", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-default-no-permission");
  writeHooks(hooksPath, {
    hooks: {
      PermissionRequest: [
        {
          matcher: "*",
          hooks: [
            { type: "command", command: expectedCodexCommand(), timeout: 600 },
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/user-permission-hook.js\"" },
          ],
        },
      ],
    },
  });

  const result = registerCodexHooks({
    codexDir,
    hooksPath,
    silent: true,
    nodeBin: "/usr/bin/node",
  });
  const settings = readHooks(hooksPath);

  assert.equal(result.added, CODEX_STATE_HOOK_EVENTS.length);
  assert.equal(result.updated, 1);
  assert.deepEqual(collectCommandHooks(settings.hooks.PermissionRequest), [
    "\"/usr/bin/node\" \"/tmp/user-permission-hook.js\"",
  ]);
});

test("registerCodexHooks can opt into permission hook", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-with-permission");

  const result = registerCodexHooks({
    codexDir,
    hooksPath,
    silent: true,
    nodeBin: "/usr/bin/node",
    includePermission: true,
  });
  const settings = readHooks(hooksPath);

  assert.equal(result.added, CODEX_HOOK_EVENTS.length);
  assert.equal(result.updated, 0);
  assert.equal(result.skipped, 0);
  assert.equal(collectCommandHooks(settings.hooks.PermissionRequest).includes(expectedCodexCommand()), true);
  assert.deepEqual(settings.hooks.PermissionRequest[0].hooks, [
    {
      type: "command",
      command: expectedCodexCommand(),
      timeout: 600,
      statusMessage: EXPECTED_STATUS_MESSAGES.PermissionRequest,
    },
  ]);
});

test("registerCodexHooks permissionOnly touches only PermissionRequest", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-permission-only");
  writeHooks(hooksPath, {
    hooks: {
      PreToolUse: [
        {
          matcher: "keep",
          hooks: [{ type: "command", command: "\"/usr/bin/node\" \"/tmp/user-hook.js\"" }],
        },
      ],
    },
  });

  const result = registerCodexHooks({
    codexDir,
    hooksPath,
    silent: true,
    nodeBin: "/usr/bin/node",
    permissionOnly: true,
  });
  const settings = readHooks(hooksPath);

  assert.deepEqual(result, { added: 1, skipped: 0, updated: 0 });
  assert.deepEqual(collectCommandHooks(settings.hooks.PreToolUse), [
    "\"/usr/bin/node\" \"/tmp/user-hook.js\"",
  ]);
  assert.equal(collectCommandHooks(settings.hooks.PermissionRequest).includes(expectedCodexCommand()), true);
});

test("unregisterCodexHooks removes only codex-hook.js entries and preserves siblings", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-uninstall");
  writeHooks(hooksPath, {
    hooks: {
      PreToolUse: [
        {
          matcher: "*",
          hooks: [
            { type: "command", command: expectedCodexCommand(), timeout: 10 },
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/user-hook.js\"" },
          ],
        },
      ],
      Stop: {
        matcher: "*",
        hooks: [
          { type: "command", command: expectedCodexCommand(), timeout: 10 },
        ],
      },
    },
  });

  const result = unregisterCodexHooks({ codexDir, hooksPath, silent: true });
  const settings = readHooks(hooksPath);

  assert.equal(result.removed, 2);
  assert.deepEqual(settings.hooks.PreToolUse, [
    {
      matcher: "*",
      hooks: [
        { type: "command", command: "\"/usr/bin/node\" \"/tmp/user-hook.js\"" },
      ],
    },
  ]);
  assert.equal(Object.prototype.hasOwnProperty.call(settings.hooks, "Stop"), false);
});

test("unregisterCodexPermissionHook removes only PermissionRequest codex hooks", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-uninstall-permission");
  writeHooks(hooksPath, {
    hooks: {
      PreToolUse: [
        {
          matcher: "*",
          hooks: [
            { type: "command", command: expectedCodexCommand(), timeout: 10 },
          ],
        },
      ],
      PermissionRequest: [
        {
          matcher: "*",
          hooks: [
            { type: "command", command: expectedCodexCommand(), timeout: 600 },
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/user-permission-hook.js\"" },
          ],
        },
      ],
    },
  });

  const result = unregisterCodexPermissionHook({ codexDir, hooksPath, silent: true });
  const settings = readHooks(hooksPath);

  assert.equal(result.removed, 1);
  assert.equal(collectCommandHooks(settings.hooks.PreToolUse).includes(expectedCodexCommand()), true);
  assert.deepEqual(collectCommandHooks(settings.hooks.PermissionRequest), [
    "\"/usr/bin/node\" \"/tmp/user-permission-hook.js\"",
  ]);
});

test("codex installer fails loudly on malformed hooks.json", () => {
  const { codexDir, hooksPath } = makeTempCodexDir("codex-invalid");
  writeRaw(hooksPath, "{ invalid json");

  assert.throws(
    () => registerCodexHooks({ codexDir, hooksPath, silent: true, nodeBin: "/usr/bin/node" }),
    /Failed to read .*hooks\.json/
  );
  assert.throws(
    () => unregisterCodexHooks({ codexDir, hooksPath, silent: true }),
    /Failed to read .*hooks\.json/
  );
});
