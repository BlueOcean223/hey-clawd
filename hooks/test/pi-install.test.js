const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  CORE_FILE,
  EXTENSION_FILE,
  MARKER_FILE,
  registerPiExtension,
  unregisterPiExtension,
} = require("../pi-install");

function makeTempDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`));
}

function writeText(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, "utf8");
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

test("registerPiExtension skips when neither ~/.pi/agent nor pi command exists", () => {
  const root = makeTempDir("pi-install-skip");
  const sourcePath = path.join(root, "pi-extension.ts");
  const sourceCorePath = path.join(root, "pi-extension-core.js");
  writeText(sourcePath, "export default function () {}\n");
  writeText(sourceCorePath, "module.exports = {};\n");

  const result = registerPiExtension({
    agentDir: path.join(root, ".pi", "agent"),
    sourceExtensionPath: sourcePath,
    sourceCorePath,
    hasPiCommand: false,
    silent: true,
  });

  assert.deepEqual(result, { installed: false, skipped: true, updated: false });
});

test("registerPiExtension installs index.ts, pi-extension-core.js and marker", () => {
  const root = makeTempDir("pi-install-add");
  const agentDir = path.join(root, ".pi", "agent");
  const sourcePath = path.join(root, "pi-extension.ts");
  const sourceCorePath = path.join(root, "pi-extension-core.js");
  writeText(sourcePath, "export default function () { console.log('pi'); }\n");
  writeText(sourceCorePath, "module.exports = { buildPayload() { return {}; }, shouldReport() { return true; } };\n");

  const result = registerPiExtension({
    agentDir,
    sourceExtensionPath: sourcePath,
    sourceCorePath,
    hasPiCommand: true,
    silent: true,
  });

  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const extensionPath = path.join(extensionDir, EXTENSION_FILE);
  const corePath = path.join(extensionDir, CORE_FILE);
  const markerPath = path.join(extensionDir, MARKER_FILE);

  assert.deepEqual(result, { installed: true, skipped: false, updated: false });
  assert.equal(fs.readFileSync(extensionPath, "utf8"), "export default function () { console.log('pi'); }\n");
  assert.equal(
    fs.readFileSync(corePath, "utf8"),
    "module.exports = { buildPayload() { return {}; }, shouldReport() { return true; } };\n"
  );

  const marker = readJson(markerPath);
  assert.equal(marker.app, "hey-clawd");
  assert.equal(marker.integration, "pi");
  assert.equal(marker.version, 1);
  assert.equal(typeof marker.installedAt, "string");
});

test("registerPiExtension updates existing managed index.ts and pi-extension-core.js in place", () => {
  const root = makeTempDir("pi-install-update");
  const agentDir = path.join(root, ".pi", "agent");
  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const extensionPath = path.join(extensionDir, EXTENSION_FILE);
  const corePath = path.join(extensionDir, CORE_FILE);
  const markerPath = path.join(extensionDir, MARKER_FILE);
  const sourcePath = path.join(root, "pi-extension.ts");
  const sourceCorePath = path.join(root, "pi-extension-core.js");

  writeText(extensionPath, "same content\n");
  writeText(corePath, "old core\n");
  writeText(markerPath, JSON.stringify({ app: "hey-clawd", integration: "pi", version: 1 }, null, 2));
  writeText(sourcePath, "same content\n");
  writeText(sourceCorePath, "new core\n");

  const result = registerPiExtension({
    agentDir,
    sourceExtensionPath: sourcePath,
    sourceCorePath,
    hasPiCommand: true,
    silent: true,
  });

  assert.deepEqual(result, { installed: true, skipped: false, updated: true });
  assert.equal(fs.readFileSync(extensionPath, "utf8"), "same content\n");
  assert.equal(fs.readFileSync(corePath, "utf8"), "new core\n");
});

test("registerPiExtension treats managed partial install recovery as updated", () => {
  const root = makeTempDir("pi-install-repair");
  const agentDir = path.join(root, ".pi", "agent");
  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const corePath = path.join(extensionDir, CORE_FILE);
  const markerPath = path.join(extensionDir, MARKER_FILE);
  const sourcePath = path.join(root, "pi-extension.ts");
  const sourceCorePath = path.join(root, "pi-extension-core.js");

  writeText(corePath, "same core\n");
  writeText(markerPath, JSON.stringify({ app: "hey-clawd", integration: "pi", version: 1 }, null, 2));
  writeText(sourcePath, "new extension\n");
  writeText(sourceCorePath, "same core\n");

  const result = registerPiExtension({
    agentDir,
    sourceExtensionPath: sourcePath,
    sourceCorePath,
    hasPiCommand: true,
    silent: true,
  });

  assert.deepEqual(result, { installed: true, skipped: false, updated: true });
  assert.equal(fs.readFileSync(path.join(extensionDir, EXTENSION_FILE), "utf8"), "new extension\n");
  assert.equal(fs.readFileSync(corePath, "utf8"), "same core\n");
});

test("registerPiExtension skips existing unmanaged extension directory", () => {
  const root = makeTempDir("pi-install-unmanaged");
  const agentDir = path.join(root, ".pi", "agent");
  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const extensionPath = path.join(extensionDir, EXTENSION_FILE);
  const sourcePath = path.join(root, "pi-extension.ts");
  const sourceCorePath = path.join(root, "pi-extension-core.js");

  writeText(extensionPath, "user managed\n");
  writeText(sourcePath, "new content\n");
  writeText(sourceCorePath, "new core\n");

  const result = registerPiExtension({
    agentDir,
    sourceExtensionPath: sourcePath,
    sourceCorePath,
    hasPiCommand: true,
    silent: true,
  });

  assert.deepEqual(result, { installed: false, skipped: true, updated: false });
  assert.equal(fs.readFileSync(extensionPath, "utf8"), "user managed\n");
});

test("installed pi-extension-core.js can be required", () => {
  const root = makeTempDir("pi-install-require");
  const agentDir = path.join(root, ".pi", "agent");
  const sourcePath = path.join(root, "pi-extension.ts");
  const sourceCorePath = path.join(root, "pi-extension-core.js");

  writeText(sourcePath, "export default function () {}\n");
  writeText(
    sourceCorePath,
    "module.exports = { shouldReport() { return true; }, buildPayload() { return {}; } };\n"
  );

  registerPiExtension({
    agentDir,
    sourceExtensionPath: sourcePath,
    sourceCorePath,
    hasPiCommand: true,
    silent: true,
  });

  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const installedCore = require(path.join(extensionDir, CORE_FILE));
  assert.equal(typeof installedCore.shouldReport, "function");
  assert.equal(typeof installedCore.buildPayload, "function");
});

test("unregisterPiExtension removes only marker-managed extension directory", () => {
  const root = makeTempDir("pi-install-clean");
  const agentDir = path.join(root, ".pi", "agent");
  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const otherDir = path.join(agentDir, "extensions", "other-extension");

  writeText(path.join(extensionDir, EXTENSION_FILE), "content\n");
  writeText(path.join(extensionDir, MARKER_FILE), JSON.stringify({ app: "hey-clawd", integration: "pi", version: 1 }, null, 2));
  writeText(path.join(otherDir, "index.ts"), "keep me\n");

  const result = unregisterPiExtension({ agentDir, silent: true });

  assert.deepEqual(result, { removed: 1, skipped: false });
  assert.equal(fs.existsSync(extensionDir), false);
  assert.equal(fs.existsSync(otherDir), true);
});

test("unregisterPiExtension skips directories without marker", () => {
  const root = makeTempDir("pi-install-safe");
  const agentDir = path.join(root, ".pi", "agent");
  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");

  writeText(path.join(extensionDir, EXTENSION_FILE), "content\n");

  const result = unregisterPiExtension({ agentDir, silent: true });

  assert.deepEqual(result, { removed: 0, skipped: true });
  assert.equal(fs.existsSync(extensionDir), true);
});
