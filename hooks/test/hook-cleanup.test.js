const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const { registerHooks, unregisterHooks, unregisterAutoStart } = require("../install");
const { registerCodeBuddyHooks, unregisterCodeBuddyHooks } = require("../codebuddy-install");
const { unregisterCursorHooks } = require("../cursor-install");
const { unregisterGeminiHooks } = require("../gemini-install");
const { buildPermissionUrl, DEFAULT_SERVER_PORT } = require("../server-config");

function makeTempSettingsPath(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`));
  return path.join(dir, "settings.json");
}

function writeSettings(settingsPath, settings) {
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), "utf8");
}

function writeRaw(settingsPath, content) {
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  fs.writeFileSync(settingsPath, content, "utf8");
}

function readSettings(settingsPath) {
  return JSON.parse(fs.readFileSync(settingsPath, "utf8"));
}

function collectHttpUrls(entries) {
  return entries.flatMap((entry) => {
    if (!entry || typeof entry !== "object") return [];
    const urls = [];
    if (entry.type === "http" && typeof entry.url === "string") {
      urls.push(entry.url);
    }
    if (Array.isArray(entry.hooks)) {
      for (const hook of entry.hooks) {
        if (hook && hook.type === "http" && typeof hook.url === "string") {
          urls.push(hook.url);
        }
      }
    }
    return urls;
  });
}

test("unregisterCodeBuddyHooks preserves sibling hooks in shared entries", () => {
  const settingsPath = makeTempSettingsPath("codebuddy-clean");
  writeSettings(settingsPath, {
    hooks: {
      SessionStart: [
        {
          matcher: "",
          hooks: [
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/codebuddy-hook.js\"" },
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/other-hook.js\"" },
          ],
        },
      ],
      PermissionRequest: [
        {
          matcher: "",
          hooks: [
            { type: "http", url: buildPermissionUrl(DEFAULT_SERVER_PORT), timeout: 600 },
            { type: "http", url: "https://example.com/permission", timeout: 30 },
          ],
        },
      ],
    },
  });

  const result = unregisterCodeBuddyHooks({ settingsPath, silent: true });
  const settings = readSettings(settingsPath);

  assert.equal(result.removed, 2);
  assert.deepEqual(settings.hooks.SessionStart, [
    {
      matcher: "",
      hooks: [
        { type: "command", command: "\"/usr/bin/node\" \"/tmp/other-hook.js\"" },
      ],
    },
  ]);
  assert.deepEqual(settings.hooks.PermissionRequest, [
    {
      matcher: "",
      hooks: [
        { type: "http", url: "https://example.com/permission", timeout: 30 },
      ],
    },
  ]);
});

test("registerHooks does not rewrite unrelated permission hooks", () => {
  const settingsPath = makeTempSettingsPath("claude-register");
  writeSettings(settingsPath, {
    hooks: {
      PermissionRequest: [
        {
          matcher: "",
          hooks: [
            { type: "http", url: "https://example.com/permission", timeout: 30 },
          ],
        },
      ],
    },
  });

  const result = registerHooks({
    settingsPath,
    silent: true,
    nodeBin: "/usr/bin/node",
    port: DEFAULT_SERVER_PORT + 1,
    claudeVersionInfo: { version: "2.1.80", source: "test", status: "known" },
  });
  const settings = readSettings(settingsPath);
  const permissionUrls = collectHttpUrls(settings.hooks.PermissionRequest);

  assert.equal(result.updated, 0);
  assert.deepEqual(permissionUrls, [
    "https://example.com/permission",
    buildPermissionUrl(DEFAULT_SERVER_PORT + 1),
  ]);
});

test("registerHooks adds PostToolBatch for Claude Code versions that support it", () => {
  const settingsPath = makeTempSettingsPath("claude-post-tool-batch");
  writeSettings(settingsPath, { hooks: {} });

  registerHooks({
    settingsPath,
    silent: true,
    nodeBin: "/usr/bin/node",
    claudeVersionInfo: { version: "2.1.119", source: "test", status: "known" },
  });
  const settings = readSettings(settingsPath);

  assert.equal(Array.isArray(settings.hooks.PostToolBatch), true);
  assert.equal(
    settings.hooks.PostToolBatch[0].hooks[0].command,
    "\"/usr/bin/node\" \"" + path.resolve(__dirname, "../clawd-hook.js").replace(/\\/g, "/") + "\" PostToolBatch"
  );
});

test("unregisterHooks removes only Clawd permission and auto-start hooks", () => {
  const settingsPath = makeTempSettingsPath("claude-clean");
  writeSettings(settingsPath, {
    hooks: {
      PermissionRequest: [
        {
          matcher: "",
          hooks: [
            { type: "http", url: buildPermissionUrl(DEFAULT_SERVER_PORT), timeout: 600 },
            { type: "http", url: "https://example.com/permission", timeout: 30 },
          ],
        },
      ],
      SessionStart: [
        {
          matcher: "",
          hooks: [
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/auto-start.js\"" },
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/another-start-hook.js\"" },
          ],
        },
      ],
    },
  });

  const result = unregisterHooks({ settingsPath, silent: true });
  const settings = readSettings(settingsPath);

  assert.equal(result.removed, 2);
  assert.deepEqual(settings.hooks.PermissionRequest, [
    {
      matcher: "",
      hooks: [
        { type: "http", url: "https://example.com/permission", timeout: 30 },
      ],
    },
  ]);
  assert.deepEqual(settings.hooks.SessionStart, [
    {
      matcher: "",
      hooks: [
        { type: "command", command: "\"/usr/bin/node\" \"/tmp/another-start-hook.js\"" },
      ],
    },
  ]);
});

test("unregisterHooks cleans legacy single-object Claude hook entries", () => {
  const settingsPath = makeTempSettingsPath("claude-clean-legacy");
  writeSettings(settingsPath, {
    hooks: {
      PermissionRequest: {
        matcher: "",
        hooks: [
          { type: "http", url: buildPermissionUrl(DEFAULT_SERVER_PORT), timeout: 600 },
        ],
      },
      SessionStart: {
        matcher: "",
        hooks: [
          { type: "command", command: "\"/usr/bin/node\" \"/tmp/auto-start.js\"" },
        ],
      },
      Stop: [
        {
          matcher: "",
          hooks: [
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/keep-me.js\"" },
          ],
        },
      ],
    },
  });

  const result = unregisterHooks({ settingsPath, silent: true });
  const settings = readSettings(settingsPath);

  assert.equal(result.removed, 2);
  assert.equal(Object.prototype.hasOwnProperty.call(settings.hooks, "PermissionRequest"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(settings.hooks, "SessionStart"), false);
  assert.deepEqual(settings.hooks.Stop, [
    {
      matcher: "",
      hooks: [
        { type: "command", command: "\"/usr/bin/node\" \"/tmp/keep-me.js\"" },
      ],
    },
  ]);
});

test("unregisterAutoStart preserves sibling SessionStart hooks", () => {
  const settingsPath = makeTempSettingsPath("autostart-clean");
  writeSettings(settingsPath, {
    hooks: {
      SessionStart: [
        {
          matcher: "",
          hooks: [
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/auto-start.js\"" },
            { type: "command", command: "\"/usr/bin/node\" \"/tmp/keep-me.js\"" },
          ],
        },
      ],
    },
  });

  const removed = unregisterAutoStart({ settingsPath });
  const settings = readSettings(settingsPath);

  assert.equal(removed, true);
  assert.deepEqual(settings.hooks.SessionStart, [
    {
      matcher: "",
      hooks: [
        { type: "command", command: "\"/usr/bin/node\" \"/tmp/keep-me.js\"" },
      ],
    },
  ]);
});

test("registerCodeBuddyHooks does not rewrite unrelated permission hooks", () => {
  const settingsPath = makeTempSettingsPath("codebuddy-register");
  writeSettings(settingsPath, {
    hooks: {
      PermissionRequest: [
        {
          matcher: "",
          hooks: [
            { type: "http", url: "https://example.com/permission", timeout: 30 },
          ],
        },
      ],
    },
  });

  const result = registerCodeBuddyHooks({
    settingsPath,
    silent: true,
    nodeBin: "/usr/bin/node",
    port: DEFAULT_SERVER_PORT + 2,
  });
  const settings = readSettings(settingsPath);
  const permissionUrls = collectHttpUrls(settings.hooks.PermissionRequest);

  assert.equal(result.updated, 0);
  assert.deepEqual(permissionUrls, [
    "https://example.com/permission",
    buildPermissionUrl(DEFAULT_SERVER_PORT + 2),
  ]);
});

test("cleanup helpers fail loudly on invalid JSON", () => {
  const claudeSettingsPath = makeTempSettingsPath("claude-invalid");
  const geminiSettingsPath = makeTempSettingsPath("gemini-invalid");
  const cursorHooksPath = makeTempSettingsPath("cursor-invalid");
  const codebuddySettingsPath = makeTempSettingsPath("codebuddy-invalid");

  writeRaw(claudeSettingsPath, "{ invalid json");
  writeRaw(geminiSettingsPath, "{ invalid json");
  writeRaw(cursorHooksPath, "{ invalid json");
  writeRaw(codebuddySettingsPath, "{ invalid json");

  assert.throws(
    () => unregisterHooks({ settingsPath: claudeSettingsPath, silent: true }),
    /Failed to read .*settings\.json/
  );
  assert.throws(
    () => unregisterGeminiHooks({ settingsPath: geminiSettingsPath, silent: true }),
    /Failed to read .*settings\.json/
  );
  assert.throws(
    () => unregisterCursorHooks({ hooksPath: cursorHooksPath, silent: true }),
    /Failed to read .*\.json/
  );
  assert.throws(
    () => unregisterCodeBuddyHooks({ settingsPath: codebuddySettingsPath, silent: true }),
    /Failed to read .*settings\.json/
  );
});
