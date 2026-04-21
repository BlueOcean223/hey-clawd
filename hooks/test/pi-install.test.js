const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
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
  writeText(sourcePath, "export default function () {}\n");

  const result = registerPiExtension({
    agentDir: path.join(root, ".pi", "agent"),
    sourceExtensionPath: sourcePath,
    hasPiCommand: false,
    silent: true,
  });

  assert.deepEqual(result, { installed: false, skipped: true, updated: false });
});

test("registerPiExtension installs self-contained index.ts and marker", () => {
  const root = makeTempDir("pi-install-add");
  const agentDir = path.join(root, ".pi", "agent");
  const sourcePath = path.join(root, "pi-extension.ts");
  writeText(sourcePath, "export default function () { console.log('pi'); }\n");

  const result = registerPiExtension({
    agentDir,
    sourceExtensionPath: sourcePath,
    hasPiCommand: true,
    silent: true,
  });

  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const extensionPath = path.join(extensionDir, EXTENSION_FILE);
  const markerPath = path.join(extensionDir, MARKER_FILE);

  assert.deepEqual(result, { installed: true, skipped: false, updated: false });
  assert.equal(fs.readFileSync(extensionPath, "utf8"), "export default function () { console.log('pi'); }\n");

  const marker = readJson(markerPath);
  assert.equal(marker.app, "hey-clawd");
  assert.equal(marker.integration, "pi");
  assert.equal(marker.version, 1);
  assert.equal(typeof marker.installedAt, "string");
});

test("registerPiExtension updates existing managed index.ts in place", () => {
  const root = makeTempDir("pi-install-update");
  const agentDir = path.join(root, ".pi", "agent");
  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const extensionPath = path.join(extensionDir, EXTENSION_FILE);
  const markerPath = path.join(extensionDir, MARKER_FILE);
  const sourcePath = path.join(root, "pi-extension.ts");

  writeText(extensionPath, "old content\n");
  writeText(markerPath, JSON.stringify({ app: "hey-clawd", integration: "pi", version: 1 }, null, 2));
  writeText(sourcePath, "new content\n");

  const result = registerPiExtension({
    agentDir,
    sourceExtensionPath: sourcePath,
    hasPiCommand: true,
    silent: true,
  });

  assert.deepEqual(result, { installed: true, skipped: false, updated: true });
  assert.equal(fs.readFileSync(extensionPath, "utf8"), "new content\n");
});

test("registerPiExtension skips existing unmanaged extension directory", () => {
  const root = makeTempDir("pi-install-unmanaged");
  const agentDir = path.join(root, ".pi", "agent");
  const extensionDir = path.join(agentDir, "extensions", "hey-clawd");
  const extensionPath = path.join(extensionDir, EXTENSION_FILE);
  const sourcePath = path.join(root, "pi-extension.ts");

  writeText(extensionPath, "user managed\n");
  writeText(sourcePath, "new content\n");

  const result = registerPiExtension({
    agentDir,
    sourceExtensionPath: sourcePath,
    hasPiCommand: true,
    silent: true,
  });

  assert.deepEqual(result, { installed: false, skipped: true, updated: false });
  assert.equal(fs.readFileSync(extensionPath, "utf8"), "user managed\n");
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
