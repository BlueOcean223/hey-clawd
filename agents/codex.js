// Codex CLI agent configuration
// Native hooks via ~/.codex/hooks.json.

module.exports = {
  id: "codex",
  name: "Codex CLI",
  processNames: { win: ["codex.exe"], mac: ["codex"], linux: ["codex"] },
  nodeCommandPatterns: [],
  eventSource: "hook",
  eventMap: {
    SessionStart: "idle",
    UserPromptSubmit: "thinking",
    PreToolUse: "working",
    PermissionRequest: "notification",
    PostToolUse: "working",
    Stop: "attention",
    PreCompact: "sweeping",
    PostCompact: "idle",
  },
  capabilities: {
    httpHook: true,
    permissionApproval: true,
    sessionEnd: false,
    subagent: false,
  },
  hookConfig: { configFormat: "codex-hooks-json" },
  stdinFormat: "codexHookJson",
  pidField: "codex_pid",
};
