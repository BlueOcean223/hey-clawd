const fs = require("fs");

// Shared hook entry manipulation utilities.
// Used by install.js, codebuddy-install.js, cursor-install.js, gemini-install.js.

/**
 * Read and parse a JSON file, distinguishing ENOENT from invalid/unreadable content.
 * @param {string} filePath
 * @returns {{ exists: boolean, data: any }}
 */
function loadJsonFile(filePath) {
  try {
    return {
      exists: true,
      data: JSON.parse(fs.readFileSync(filePath, "utf-8")),
    };
  } catch (err) {
    if (err && err.code === "ENOENT") {
      return { exists: false, data: null };
    }
    throw new Error(`Failed to read ${filePath}: ${err.message}`);
  }
}

/**
 * Normalize a hook event value to the modern array format.
 * Legacy Claude Code settings may store a single object instead.
 * @param {any} value
 * @returns {{ entries: Array|null, changed: boolean }}
 */
function normalizeHookEntries(value) {
  if (Array.isArray(value)) return { entries: value, changed: false };
  if (value && typeof value === "object") return { entries: [value], changed: true };
  return { entries: null, changed: false };
}

/**
 * Remove command hooks matching `predicate` from an entries array.
 * Works on both flat ({ command }) and nested ({ matcher, hooks: [{ command }] }) formats.
 * Only the matching hooks are removed — sibling hooks in shared entries are preserved.
 * @param {Array} entries
 * @param {(command: string) => boolean} predicate
 * @returns {{ entries: Array, removed: number, changed: boolean }}
 */
function removeMatchingCommandHooks(entries, predicate) {
  if (!Array.isArray(entries)) return { entries, removed: 0, changed: false };

  let removed = 0;
  let changed = false;
  const nextEntries = [];

  for (const entry of entries) {
    if (!entry || typeof entry !== "object") {
      nextEntries.push(entry);
      continue;
    }

    let entryChanged = false;
    const nextEntry = { ...entry };

    if (typeof entry.command === "string" && predicate(entry.command)) {
      delete nextEntry.command;
      removed++;
      changed = true;
      entryChanged = true;
    }

    if (Array.isArray(entry.hooks)) {
      const nextHooks = entry.hooks.filter((hook) => {
        if (!hook || typeof hook !== "object" || typeof hook.command !== "string") return true;
        if (!predicate(hook.command)) return true;
        removed++;
        changed = true;
        entryChanged = true;
        return false;
      });

      if (nextHooks.length > 0) {
        nextEntry.hooks = nextHooks;
      } else {
        delete nextEntry.hooks;
      }
    }

    if (!entryChanged) {
      nextEntries.push(entry);
      continue;
    }

    if (typeof nextEntry.command !== "string" && !Array.isArray(nextEntry.hooks)) {
      continue;
    }

    nextEntries.push(nextEntry);
  }

  return { entries: nextEntries, removed, changed };
}

/**
 * Remove HTTP hooks matching `predicate` from an entries array.
 * Works on both flat ({ type: "http", url }) and nested ({ hooks: [{ type: "http", url }] }) formats.
 * Only the matching hooks are removed — sibling hooks in shared entries are preserved.
 * @param {Array} entries
 * @param {(url: string) => boolean} predicate
 * @returns {{ entries: Array, removed: number, changed: boolean }}
 */
function removeMatchingHttpHooks(entries, predicate) {
  if (!Array.isArray(entries)) return { entries, removed: 0, changed: false };

  let removed = 0;
  let changed = false;
  const nextEntries = [];

  for (const entry of entries) {
    if (!entry || typeof entry !== "object") {
      nextEntries.push(entry);
      continue;
    }

    let entryChanged = false;
    const nextEntry = { ...entry };

    if (entry.type === "http" && predicate(entry.url)) {
      delete nextEntry.type;
      delete nextEntry.url;
      if (Object.prototype.hasOwnProperty.call(nextEntry, "timeout")) {
        delete nextEntry.timeout;
      }
      removed++;
      changed = true;
      entryChanged = true;
    }

    if (Array.isArray(entry.hooks)) {
      const nextHooks = entry.hooks.filter((hook) => {
        if (!hook || typeof hook !== "object" || hook.type !== "http") return true;
        if (!predicate(hook.url)) return true;
        removed++;
        changed = true;
        entryChanged = true;
        return false;
      });

      if (nextHooks.length > 0) {
        nextEntry.hooks = nextHooks;
      } else {
        delete nextEntry.hooks;
      }
    }

    if (!entryChanged) {
      nextEntries.push(entry);
      continue;
    }

    const hasTopLevelHttp = nextEntry.type === "http" && typeof nextEntry.url === "string";
    if (!hasTopLevelHttp && typeof nextEntry.command !== "string" && !Array.isArray(nextEntry.hooks)) {
      continue;
    }

    nextEntries.push(nextEntry);
  }

  return { entries: nextEntries, removed, changed };
}

module.exports = { loadJsonFile, normalizeHookEntries, removeMatchingCommandHooks, removeMatchingHttpHooks };
