#!/usr/bin/env node
// Merge Clawd CodeBuddy hooks into ~/.codebuddy/settings.json (append-only, idempotent)
// CodeBuddy uses Claude Code-compatible hook format: { matcher, hooks: [{ type, command }] }

const fs = require("fs");
const path = require("path");
const os = require("os");
const { resolveNodeBin, buildPermissionUrl, DEFAULT_SERVER_PORT, readRuntimePort, SERVER_PORTS } = require("./server-config");
const { loadJsonFile, removeMatchingCommandHooks, removeMatchingHttpHooks } = require("./hook-utils");
const MARKER = "codebuddy-hook.js";
const CLAWD_PERMISSION_URLS = new Set(SERVER_PORTS.map((port) => buildPermissionUrl(port)));

function isClawdPermissionUrl(url) {
  return typeof url === "string" && CLAWD_PERMISSION_URLS.has(url);
}

function parsePortArg(argv) {
  const index = argv.indexOf("--port");
  if (index === -1 || index + 1 >= argv.length) {
    return null;
  }

  const value = Number(argv[index + 1]);
  return Number.isInteger(value) ? value : null;
}

/** Extract the existing absolute node path from hook commands containing marker. */
function extractExistingNodeBin(settings, marker) {
  if (!settings || !settings.hooks) return null;
  for (const entries of Object.values(settings.hooks)) {
    if (!Array.isArray(entries)) continue;
    for (const entry of entries) {
      if (!entry || typeof entry !== "object") continue;
      // Check nested hooks array (Claude Code format)
      const innerHooks = entry.hooks;
      if (Array.isArray(innerHooks)) {
        for (const h of innerHooks) {
          if (!h || typeof h.command !== "string") continue;
          if (!h.command.includes(marker)) continue;
          const qi = h.command.indexOf('"');
          if (qi === -1) continue;
          const qe = h.command.indexOf('"', qi + 1);
          if (qe === -1) continue;
          const first = h.command.substring(qi + 1, qe);
          if (!first.includes(marker) && first.startsWith("/")) return first;
        }
      }
      // Also check flat format for migration
      const cmd = entry.command;
      if (typeof cmd === "string" && cmd.includes(marker)) {
        const qi = cmd.indexOf('"');
        if (qi === -1) continue;
        const qe = cmd.indexOf('"', qi + 1);
        if (qe === -1) continue;
        const first = cmd.substring(qi + 1, qe);
        if (!first.includes(marker) && first.startsWith("/")) return first;
      }
    }
  }
  return null;
}

// CodeBuddy supported hook events (as of v1.16+)
const CODEBUDDY_HOOK_EVENTS = [
  "SessionStart",
  "SessionEnd",
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "Stop",
  "Notification",
  "PreCompact",
];

function writeJsonAtomic(filePath, data) {
  const dir = path.dirname(filePath);
  const base = path.basename(filePath);
  const tmpPath = path.join(dir, `.${base}.${process.pid}.${Date.now()}.tmp`);
  fs.mkdirSync(dir, { recursive: true });
  try {
    fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2), "utf-8");
    fs.renameSync(tmpPath, filePath);
  } catch (err) {
    try { fs.unlinkSync(tmpPath); } catch {}
    throw err;
  }
}

/**
 * Register Clawd hooks into ~/.codebuddy/settings.json
 * Uses Claude Code-compatible nested format: { matcher, hooks: [{ type, command }] }
 * @param {object} [options]
 * @param {boolean} [options.silent]
 * @param {string} [options.settingsPath]
 * @returns {{ added: number, skipped: number, updated: number }}
 */
function registerCodeBuddyHooks(options = {}) {
  const settingsPath = options.settingsPath || path.join(os.homedir(), ".codebuddy", "settings.json");

  // Skip if ~/.codebuddy/ doesn't exist (CodeBuddy not installed)
  const codebuddyDir = path.dirname(settingsPath);
  if (!options.settingsPath && !fs.existsSync(codebuddyDir)) {
    if (!options.silent) console.log("Clawd: ~/.codebuddy/ not found — skipping CodeBuddy hook registration");
    return { added: 0, skipped: 0, updated: 0 };
  }

  let hookScript = path.resolve(__dirname, "codebuddy-hook.js").replace(/\\/g, "/");
  hookScript = hookScript.replace("app.asar/", "app.asar.unpacked/");

  let settings = {};
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf-8"));
  } catch (err) {
    if (err.code !== "ENOENT") {
      throw new Error(`Failed to read settings.json: ${err.message}`);
    }
  }

  // Resolve node path; if detection fails, preserve existing absolute path
  const resolved = options.nodeBin !== undefined ? options.nodeBin : resolveNodeBin();
  const nodeBin = resolved
    || extractExistingNodeBin(settings, MARKER)
    || "node";
  const desiredCommand = `"${nodeBin}" "${hookScript}"`;

  if (!settings.hooks || typeof settings.hooks !== "object") settings.hooks = {};

  let added = 0;
  let skipped = 0;
  let updated = 0;
  let changed = false;

  for (const event of CODEBUDDY_HOOK_EVENTS) {
    if (!Array.isArray(settings.hooks[event])) {
      settings.hooks[event] = [];
      changed = true;
    }

    const arr = settings.hooks[event];
    let found = false;
    let stalePath = false;

    for (const entry of arr) {
      if (!entry || typeof entry !== "object") continue;
      // Check nested hooks array (Claude Code format)
      const innerHooks = entry.hooks;
      if (Array.isArray(innerHooks)) {
        for (const h of innerHooks) {
          if (!h || !h.command) continue;
          if (!h.command.includes(MARKER)) continue;
          found = true;
          if (h.command !== desiredCommand) {
            h.command = desiredCommand;
            stalePath = true;
          }
          break;
        }
      }
      // Also check flat format for migration
      if (!found && entry.command && entry.command.includes(MARKER)) {
        found = true;
        if (entry.command !== desiredCommand) {
          entry.command = desiredCommand;
          stalePath = true;
        }
      }
      if (found) break;
    }

    if (found) {
      if (stalePath) {
        updated++;
        changed = true;
      } else {
        skipped++;
      }
      continue;
    }

    // Add in Claude Code-compatible nested format
    arr.push({
      matcher: "",
      hooks: [{ type: "command", command: desiredCommand }],
    });
    added++;
    changed = true;
  }

  // Register PermissionRequest HTTP hook (blocking, for permission bubble)
  const hookPort = Number.isInteger(options.port)
    ? options.port
    : (readRuntimePort() || DEFAULT_SERVER_PORT);
  const permissionUrl = buildPermissionUrl(hookPort);
  const permEvent = "PermissionRequest";
  if (!Array.isArray(settings.hooks[permEvent])) {
    settings.hooks[permEvent] = [];
    changed = true;
  }
  let permFound = false;
  for (const entry of settings.hooks[permEvent]) {
    if (!entry || typeof entry !== "object") continue;
    const innerHooks = entry.hooks;
    if (Array.isArray(innerHooks)) {
      for (const h of innerHooks) {
        if (!h || h.type !== "http" || typeof h.url !== "string") continue;
        if (!isClawdPermissionUrl(h.url)) continue;
        permFound = true;
        if (h.url !== permissionUrl) { h.url = permissionUrl; updated++; changed = true; }
        break;
      }
    }
    if (!permFound && entry.type === "http" && isClawdPermissionUrl(entry.url)) {
      permFound = true;
      if (entry.url !== permissionUrl) { entry.url = permissionUrl; updated++; changed = true; }
    }
    if (permFound) break;
  }
  if (!permFound) {
    settings.hooks[permEvent].push({
      matcher: "",
      hooks: [{ type: "http", url: permissionUrl, timeout: 600 }],
    });
    added++;
    changed = true;
  }

  if (added > 0 || changed) {
    writeJsonAtomic(settingsPath, settings);
  }

  if (!options.silent) {
    console.log(`Clawd CodeBuddy hooks → ${settingsPath}`);
    console.log(`  Added: ${added}, updated: ${updated}, skipped: ${skipped}`);
  }

  return { added, skipped, updated };
}

/**
 * Remove all Clawd hooks from ~/.codebuddy/settings.json.
 * @param {object} [options]
 * @param {boolean} [options.silent]
 * @param {string} [options.settingsPath]
 * @returns {{ removed: number }}
 */
function unregisterCodeBuddyHooks(options = {}) {
  const settingsPath = options.settingsPath || path.join(os.homedir(), ".codebuddy", "settings.json");
  const loaded = loadJsonFile(settingsPath);
  if (!loaded.exists) {
    if (!options.silent) console.log("No ~/.codebuddy/settings.json found — nothing to clean.");
    return { removed: 0 };
  }
  const settings = loaded.data;

  if (!settings.hooks) {
    if (!options.silent) console.log("No hooks in settings.json — nothing to clean.");
    return { removed: 0 };
  }

  let totalRemoved = 0;
  let changed = false;

  for (const event of Object.keys(settings.hooks)) {
    if (!Array.isArray(settings.hooks[event])) continue;
    const commandResult = removeMatchingCommandHooks(
      settings.hooks[event],
      (command) => command.includes(MARKER)
    );
    if (commandResult.changed) {
      settings.hooks[event] = commandResult.entries;
      totalRemoved += commandResult.removed;
      changed = true;
    }

    const httpResult = removeMatchingHttpHooks(
      settings.hooks[event],
      (url) => isClawdPermissionUrl(url)
    );
    if (httpResult.changed) {
      settings.hooks[event] = httpResult.entries;
      totalRemoved += httpResult.removed;
      changed = true;
    }
    if (settings.hooks[event].length === 0) delete settings.hooks[event];
  }

  if (changed) writeJsonAtomic(settingsPath, settings);

  if (!options.silent) {
    console.log(`Clawd CodeBuddy hooks cleaned from ${settingsPath}`);
    console.log(`  Removed: ${totalRemoved} hooks`);
  }

  return { removed: totalRemoved };
}

module.exports = { registerCodeBuddyHooks, unregisterCodeBuddyHooks, CODEBUDDY_HOOK_EVENTS };

if (require.main === module) {
  try {
    if (process.argv.includes("--uninstall")) {
      unregisterCodeBuddyHooks({});
    } else {
      const port = parsePortArg(process.argv);
      registerCodeBuddyHooks({ port });
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}
