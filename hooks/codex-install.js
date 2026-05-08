#!/usr/bin/env node
// Merge Clawd Codex CLI hooks into ~/.codex/hooks.json (append-only, idempotent)

const fs = require("fs");
const path = require("path");
const os = require("os");
const { resolveNodeBin } = require("./server-config");
const { loadJsonFile, normalizeHookEntries, removeMatchingCommandHooks } = require("./hook-utils");

const MARKER = "codex-hook.js";

const CODEX_HOOK_EVENTS = [
  "SessionStart",
  "UserPromptSubmit",
  "PreToolUse",
  "PermissionRequest",
  "PostToolUse",
  "Stop",
  "PreCompact",
  "PostCompact",
];

const EVENT_STATUS_MESSAGES = {
  SessionStart: "Clawd: session started",
  UserPromptSubmit: "Clawd: thinking",
  PreToolUse: "Clawd: working",
  PermissionRequest: "Clawd: waiting for permission",
  PostToolUse: "Clawd: working",
  Stop: "Clawd: attention",
  PreCompact: "Clawd: compacting",
  PostCompact: "Clawd: idle",
};

function codexPaths(options = {}) {
  const codexDir = options.codexDir || (
    options.hooksPath ? path.dirname(options.hooksPath) : path.join(os.homedir(), ".codex")
  );
  return {
    codexDir,
    hooksPath: options.hooksPath || path.join(codexDir, "hooks.json"),
  };
}

function collectCommandHooks(entries) {
  if (!Array.isArray(entries)) return [];
  const commands = [];

  for (const entry of entries) {
    if (!entry || typeof entry !== "object") continue;
    if (typeof entry.command === "string") commands.push(entry.command);
    if (!Array.isArray(entry.hooks)) continue;
    for (const hook of entry.hooks) {
      if (hook && typeof hook === "object" && typeof hook.command === "string") {
        commands.push(hook.command);
      }
    }
  }

  return commands;
}

function extractExistingNodeBin(settings, marker) {
  if (!settings || !settings.hooks || typeof settings.hooks !== "object") return null;
  for (const entries of Object.values(settings.hooks)) {
    const normalized = normalizeHookEntries(entries);
    for (const command of collectCommandHooks(normalized.entries)) {
      if (!command.includes(marker)) continue;
      const qi = command.indexOf("\"");
      if (qi === -1) continue;
      const qe = command.indexOf("\"", qi + 1);
      if (qe === -1) continue;
      const first = command.substring(qi + 1, qe);
      if (!first.includes(marker) && first.startsWith("/")) return first;
    }
  }
  return null;
}

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

function desiredHookEntry(event, command) {
  return {
    matcher: "*",
    hooks: [
      {
        type: "command",
        command,
        timeout: event === "PermissionRequest" ? 600 : 10,
        statusMessage: EVENT_STATUS_MESSAGES[event],
      },
    ],
  };
}

function isDesiredHookEntry(entries, expectedEntry, expectedCommand) {
  let markerCount = 0;
  let hasDesired = false;

  for (const entry of entries) {
    if (!entry || typeof entry !== "object") continue;
    if (typeof entry.command === "string" && entry.command.includes(MARKER)) {
      markerCount++;
    }

    if (!Array.isArray(entry.hooks)) continue;
    for (const hook of entry.hooks) {
      if (!hook || typeof hook !== "object" || typeof hook.command !== "string") continue;
      if (!hook.command.includes(MARKER)) continue;
      markerCount++;
      hasDesired = (
        entry.matcher === expectedEntry.matcher &&
        hook.type === expectedEntry.hooks[0].type &&
        hook.command === expectedCommand &&
        hook.timeout === expectedEntry.hooks[0].timeout &&
        hook.statusMessage === expectedEntry.hooks[0].statusMessage
      );
    }
  }

  return markerCount === 1 && hasDesired;
}

function syncCodexHookEntries(entries, event, command) {
  const expectedEntry = desiredHookEntry(event, command);
  const markerCount = collectCommandHooks(entries)
    .filter((existingCommand) => existingCommand.includes(MARKER))
    .length;

  if (isDesiredHookEntry(entries, expectedEntry, command)) {
    return { entries, added: false, updated: false };
  }

  const cleaned = removeMatchingCommandHooks(
    entries,
    (existingCommand) => existingCommand.includes(MARKER)
  );
  const nextEntries = cleaned.entries.slice();
  nextEntries.push(expectedEntry);

  return {
    entries: nextEntries,
    added: markerCount === 0,
    updated: markerCount > 0,
  };
}

function loadHooksFile(hooksPath) {
  const loaded = loadJsonFile(hooksPath);
  if (!loaded.exists) {
    return {};
  }
  if (!loaded.data || typeof loaded.data !== "object" || Array.isArray(loaded.data)) {
    throw new Error(`Failed to read ${hooksPath}: root object is not a JSON object`);
  }
  return loaded.data;
}

/**
 * Register Clawd hooks into ~/.codex/hooks.json.
 * @param {object} [options]
 * @param {boolean} [options.silent]
 * @param {string} [options.codexDir]
 * @param {string} [options.hooksPath]
 * @param {string|null} [options.nodeBin]
 * @returns {{ added: number, skipped: number, updated: number }}
 */
function registerCodexHooks(options = {}) {
  const { codexDir, hooksPath } = codexPaths(options);

  if (!fs.existsSync(codexDir)) {
    if (!options.silent) console.log("Clawd: ~/.codex/ not found — skipping Codex hook registration");
    return { added: 0, skipped: 0, updated: 0 };
  }

  const settings = loadHooksFile(hooksPath);
  if (!settings.hooks || typeof settings.hooks !== "object" || Array.isArray(settings.hooks)) {
    settings.hooks = {};
  }

  const resolved = options.nodeBin !== undefined ? options.nodeBin : resolveNodeBin();
  const nodeBin = resolved
    || extractExistingNodeBin(settings, MARKER)
    || "node";
  let hookScript = path.resolve(__dirname, "codex-hook.js").replace(/\\/g, "/");
  hookScript = hookScript.replace("app.asar/", "app.asar.unpacked/");
  const desiredCommand = `"${nodeBin}" "${hookScript}"`;

  let added = 0;
  let skipped = 0;
  let updated = 0;
  let changed = false;

  for (const event of CODEX_HOOK_EVENTS) {
    const normalized = normalizeHookEntries(settings.hooks[event]);
    if (!normalized.entries) {
      settings.hooks[event] = [];
      changed = true;
    } else if (normalized.changed) {
      settings.hooks[event] = normalized.entries;
      changed = true;
    }

    const syncResult = syncCodexHookEntries(settings.hooks[event], event, desiredCommand);
    settings.hooks[event] = syncResult.entries;

    if (syncResult.added) {
      added++;
      changed = true;
    } else if (syncResult.updated) {
      updated++;
      changed = true;
    } else {
      skipped++;
    }
  }

  if (changed) {
    writeJsonAtomic(hooksPath, settings);
  }

  if (!options.silent) {
    console.log(`Clawd Codex hooks → ${hooksPath}`);
    console.log(`  Added: ${added}, updated: ${updated}, skipped: ${skipped}`);
  }

  return { added, skipped, updated };
}

/**
 * Remove all Clawd hooks from ~/.codex/hooks.json.
 * @param {object} [options]
 * @param {boolean} [options.silent]
 * @param {string} [options.codexDir]
 * @param {string} [options.hooksPath]
 * @returns {{ removed: number }}
 */
function unregisterCodexHooks(options = {}) {
  const { hooksPath } = codexPaths(options);
  const loaded = loadJsonFile(hooksPath);
  if (!loaded.exists) {
    if (!options.silent) console.log("No ~/.codex/hooks.json found — nothing to clean.");
    return { removed: 0 };
  }
  const settings = loaded.data;

  if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
    throw new Error(`Failed to read ${hooksPath}: root object is not a JSON object`);
  }
  if (!settings.hooks || typeof settings.hooks !== "object") {
    if (!options.silent) console.log("No hooks in hooks.json — nothing to clean.");
    return { removed: 0 };
  }

  let totalRemoved = 0;
  let changed = false;

  for (const event of Object.keys(settings.hooks)) {
    const normalized = normalizeHookEntries(settings.hooks[event]);
    if (!normalized.entries) continue;
    if (normalized.changed) {
      settings.hooks[event] = normalized.entries;
      changed = true;
    }

    const result = removeMatchingCommandHooks(
      settings.hooks[event],
      (command) => command.includes(MARKER)
    );
    if (result.changed) {
      settings.hooks[event] = result.entries;
      totalRemoved += result.removed;
      changed = true;
    }
    if (settings.hooks[event].length === 0) delete settings.hooks[event];
  }

  if (changed) writeJsonAtomic(hooksPath, settings);

  if (!options.silent) {
    console.log(`Clawd Codex hooks cleaned from ${hooksPath}`);
    console.log(`  Removed: ${totalRemoved} hooks`);
  }

  return { removed: totalRemoved };
}

module.exports = { registerCodexHooks, unregisterCodexHooks, CODEX_HOOK_EVENTS };

if (require.main === module) {
  try {
    if (process.argv.includes("--uninstall")) {
      unregisterCodexHooks({});
    } else {
      registerCodexHooks({});
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}
