#!/usr/bin/env node
// Install/uninstall hey-clawd Pi extension in ~/.pi/agent/extensions/hey-clawd/

const fs = require("fs");
const path = require("path");
const os = require("os");
const { resolveNodeBin } = require("./server-config");

const EXTENSION_DIR_NAME = "hey-clawd";
const MARKER_FILE = ".clawd-managed.json";
const EXTENSION_FILE = "index.ts";

function writeTextAtomic(filePath, content) {
  const dir = path.dirname(filePath);
  const base = path.basename(filePath);
  const tmpPath = path.join(dir, `.${base}.${process.pid}.${Date.now()}.tmp`);
  fs.mkdirSync(dir, { recursive: true });
  try {
    fs.writeFileSync(tmpPath, content, "utf8");
    fs.renameSync(tmpPath, filePath);
  } catch (err) {
    try { fs.unlinkSync(tmpPath); } catch {}
    throw err;
  }
}

function writeJsonAtomic(filePath, value) {
  writeTextAtomic(filePath, JSON.stringify(value, null, 2) + "\n");
}

function resolvePiAgentDir(options = {}) {
  return options.agentDir || path.join(os.homedir(), ".pi", "agent");
}

function resolveExtensionDir(options = {}) {
  return options.extensionDir || path.join(resolvePiAgentDir(options), "extensions", EXTENSION_DIR_NAME);
}

function resolveSourceExtensionPath(options = {}) {
  if (options.sourceExtensionPath) return options.sourceExtensionPath;
  let sourcePath = path.resolve(__dirname, "pi-extension.ts").replace(/\\/g, "/");
  sourcePath = sourcePath.replace("app.asar/", "app.asar.unpacked/");
  return sourcePath;
}

function hasPiCommand(options = {}) {
  if (typeof options.hasPiCommand === "boolean") return options.hasPiCommand;

  const platform = options.platform || process.platform;
  const execFileSync = options.execFileSync || require("child_process").execFileSync;
  const accessSync = options.accessSync || fs.accessSync;
  const nodeBin = options.nodeBin !== undefined ? options.nodeBin : resolveNodeBin();

  if (nodeBin && nodeBin !== "node") {
    const siblingPi = path.join(path.dirname(nodeBin), platform === "win32" ? "pi.cmd" : "pi");
    try {
      accessSync(siblingPi, fs.constants.X_OK);
      return true;
    } catch {}
  }

  try {
    if (platform === "win32") {
      execFileSync("where", ["pi"], { encoding: "utf8", timeout: 3000, windowsHide: true });
      return true;
    }

    for (const shell of ["/bin/zsh", "/bin/bash"]) {
      try {
        const raw = execFileSync(shell, ["-lic", "which pi"], {
          encoding: "utf8",
          timeout: 3000,
          windowsHide: true,
        });
        if (raw.split("\n").some((line) => line.trim().startsWith("/"))) return true;
      } catch {}
    }

    execFileSync("which", ["pi"], { encoding: "utf8", timeout: 3000, windowsHide: true });
    return true;
  } catch {
    return false;
  }
}

function buildMarker() {
  return {
    app: "hey-clawd",
    integration: "pi",
    version: 1,
    installedAt: new Date().toISOString(),
  };
}

function isManagedMarker(value) {
  return !!value && value.app === "hey-clawd" && value.integration === "pi";
}

function loadMarker(markerPath) {
  try {
    return JSON.parse(fs.readFileSync(markerPath, "utf8"));
  } catch {
    return null;
  }
}

function registerPiExtension(options = {}) {
  const agentDir = resolvePiAgentDir(options);
  const extensionDir = resolveExtensionDir(options);
  const sourceExtensionPath = resolveSourceExtensionPath(options);
  const extensionPath = path.join(extensionDir, EXTENSION_FILE);
  const markerPath = path.join(extensionDir, MARKER_FILE);
  const agentDirExists = fs.existsSync(agentDir);
  const piCommandAvailable = hasPiCommand(options);
  const extensionDirExists = fs.existsSync(extensionDir);

  if (!agentDirExists && !piCommandAvailable) {
    if (!options.silent) console.log("Clawd: ~/.pi/agent/ and pi command not found — skipping Pi extension registration");
    return { installed: false, skipped: true, updated: false };
  }

  if (extensionDirExists) {
    const marker = loadMarker(markerPath);
    if (!isManagedMarker(marker)) {
      if (!options.silent) console.log("Pi extension directory exists but is not managed by hey-clawd — skipping install.");
      return { installed: false, skipped: true, updated: false };
    }
  }

  let extensionSource;
  try {
    extensionSource = fs.readFileSync(sourceExtensionPath, "utf8");
  } catch (err) {
    throw new Error(`Failed to read pi-extension.ts: ${err.message}`);
  }

  const previousExtension = fs.existsSync(extensionPath)
    ? fs.readFileSync(extensionPath, "utf8")
    : null;
  const updated = previousExtension !== null && previousExtension !== extensionSource;

  fs.mkdirSync(extensionDir, { recursive: true });
  writeTextAtomic(extensionPath, extensionSource);
  writeJsonAtomic(markerPath, buildMarker());

  if (!options.silent) {
    console.log(`Clawd Pi extension → ${extensionDir}`);
    console.log(`  ${updated ? "Updated" : "Installed"}: ${EXTENSION_FILE}`);
  }

  return { installed: true, skipped: false, updated };
}

function unregisterPiExtension(options = {}) {
  const extensionDir = resolveExtensionDir(options);
  const markerPath = path.join(extensionDir, MARKER_FILE);

  if (!fs.existsSync(extensionDir)) {
    if (!options.silent) console.log("No ~/.pi/agent/extensions/hey-clawd found — nothing to clean.");
    return { removed: 0, skipped: true };
  }

  if (!fs.existsSync(markerPath)) {
    if (!options.silent) console.log("Pi extension directory exists but is not managed by hey-clawd — skipping cleanup.");
    return { removed: 0, skipped: true };
  }

  const marker = loadMarker(markerPath);
  if (!isManagedMarker(marker)) {
    if (!options.silent) console.log("Pi extension directory exists but marker does not belong to hey-clawd — skipping cleanup.");
    return { removed: 0, skipped: true };
  }

  fs.rmSync(extensionDir, { recursive: true, force: true });

  if (!options.silent) {
    console.log(`Clawd Pi extension cleaned from ${extensionDir}`);
    console.log("  Removed: 1 extension directory");
  }

  return { removed: 1, skipped: false };
}

module.exports = {
  EXTENSION_DIR_NAME,
  EXTENSION_FILE,
  MARKER_FILE,
  hasPiCommand,
  isManagedMarker,
  loadMarker,
  registerPiExtension,
  resolveExtensionDir,
  resolvePiAgentDir,
  unregisterPiExtension,
};

if (require.main === module) {
  try {
    if (process.argv.includes("--uninstall")) {
      unregisterPiExtension({});
    } else {
      registerPiExtension({});
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}
