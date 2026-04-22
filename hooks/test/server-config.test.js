const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const { resolveNodeBin } = require("../server-config");

function makeTempDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`));
}

test("resolveNodeBin finds the newest nvm node before shell fallback", () => {
  const root = makeTempDir("server-config-nvm");
  const oldNode = path.join(root, ".nvm", "versions", "node", "v20.10.0", "bin", "node");
  const newNode = path.join(root, ".nvm", "versions", "node", "v22.19.0", "bin", "node");

  fs.mkdirSync(path.dirname(oldNode), { recursive: true });
  fs.mkdirSync(path.dirname(newNode), { recursive: true });
  fs.writeFileSync(oldNode, "");
  fs.writeFileSync(newNode, "");
  fs.chmodSync(oldNode, 0o755);
  fs.chmodSync(newNode, 0o755);

  const resolved = resolveNodeBin({
    homeDir: root,
    isElectron: true,
    accessSync: (candidate) => {
      if (candidate === oldNode || candidate === newNode) return;
      throw new Error("not executable");
    },
    execFileSync: () => {
      throw new Error("shell fallback should not run");
    },
  });

  assert.equal(resolved, newNode);
});

test("resolveNodeBin prefers nvm over homebrew when both exist", () => {
  const root = makeTempDir("server-config-prefer-nvm");
  const nvmNode = path.join(root, ".nvm", "versions", "node", "v22.19.0", "bin", "node");

  fs.mkdirSync(path.dirname(nvmNode), { recursive: true });
  fs.writeFileSync(nvmNode, "");
  fs.chmodSync(nvmNode, 0o755);

  const resolved = resolveNodeBin({
    homeDir: root,
    isElectron: true,
    accessSync: (candidate) => {
      if (candidate === nvmNode || candidate === "/opt/homebrew/bin/node") return;
      throw new Error("not executable");
    },
  });

  assert.equal(resolved, nvmNode);
});
