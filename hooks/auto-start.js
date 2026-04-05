#!/usr/bin/env node
// Clawd Desktop Pet — Auto-Start Script
// Registered as a SessionStart hook BEFORE clawd-hook.js.
// Checks if the Electron app is running; if not, launches it detached.
// Uses shared server discovery helpers and should exit quickly in normal cases.

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const { discoverClawdPort } = require("./server-config");

const TIMEOUT_MS = 300;
const APP_NAME = "hey-clawd";

discoverClawdPort({ timeoutMs: TIMEOUT_MS }, (port) => {
  if (port) {
    process.exit(0);
    return;
  }
  launchApp();
  process.exit(0);
});

function launchApp() {
  const isPackaged = __dirname.includes("app.asar");
  const isWin = process.platform === "win32";
  const isMac = process.platform === "darwin";

  try {
    if (isPackaged) {
      if (isWin) {
        // __dirname: <install>/resources/app.asar.unpacked/hooks
        // exe:       <install>/hey-clawd.exe
        const installDir = path.resolve(__dirname, "..", "..", "..");
        const exe = path.join(installDir, `${APP_NAME}.exe`);
        spawn(exe, [], { detached: true, stdio: "ignore" }).unref();
      } else if (isMac) {
        // __dirname: <name>.app/Contents/Resources/app.asar.unpacked/hooks
        // .app bundle: 4 levels up
        const appBundle = path.resolve(__dirname, "..", "..", "..", "..");
        spawn("open", ["-a", appBundle], {
          detached: true,
          stdio: "ignore",
        }).unref();
      } else {
        // Linux packaged app:
        // AppImage: process.env.APPIMAGE holds the .AppImage file path.
        // deb/dir:  executable is <install>/hey-clawd, same depth as Windows.
        //   __dirname: <install>/resources/app.asar.unpacked/hooks
        //   install:   3 levels up
        const appImage = process.env.APPIMAGE;
        if (appImage) {
          spawn(appImage, [], { detached: true, stdio: "ignore" }).unref();
        } else {
          const installDir = path.resolve(__dirname, "..", "..", "..");
          const exe = path.join(installDir, APP_NAME);
          spawn(exe, [], { detached: true, stdio: "ignore" }).unref();
        }
      }
    } else {
      // Source / development mode:
      // 优先直接拉起已经 build 好的二进制，找不到再回退到 swift run。
      const projectDir = path.resolve(__dirname, "..");
      const binary = resolveDevelopmentBinary(projectDir);
      if (binary) {
        spawn(binary, [], { cwd: projectDir, detached: true, stdio: "ignore" }).unref();
        return;
      }

      const swift = isWin ? "swift.exe" : "swift";
      spawn(swift, ["run", APP_NAME], {
        cwd: projectDir,
        detached: true,
        stdio: "ignore",
      }).unref();
    }
  } catch (err) {
    process.stderr.write(`clawd auto-start: ${err.message}\n`);
  }
}

function resolveDevelopmentBinary(projectDir) {
  const candidates = [
    path.join(projectDir, ".build", "debug", APP_NAME),
    path.join(projectDir, ".build", "release", APP_NAME),
  ];

  try {
    const buildDir = path.join(projectDir, ".build");
    for (const entry of fs.readdirSync(buildDir)) {
      candidates.push(path.join(buildDir, entry, "debug", APP_NAME));
      candidates.push(path.join(buildDir, entry, "release", APP_NAME));
    }
  } catch {}

  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {}
  }

  return null;
}
