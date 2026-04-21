// Pi coding agent configuration
// Integration via Pi extension installed in ~/.pi/agent/extensions/hey-clawd/

module.exports = {
  id: "pi",
  name: "Pi",
  processNames: { win: ["pi.exe"], mac: ["pi"], linux: ["pi"] },
  nodeCommandPatterns: ["@mariozechner/pi-coding-agent", "pi-coding-agent/dist/cli.js"],
  eventSource: "extension",
  eventMap: {
    SessionStart: "idle",
    UserPromptSubmit: "thinking",
    PreToolUse: "working",
    PostToolUse: "working",
    PostToolUseFailure: "working",
    Stop: "attention",
    PreCompact: "sweeping",
    PostCompact: "attention",
    SessionEnd: "sleeping",
  },
  capabilities: {
    httpHook: false,
    permissionApproval: false,
    sessionEnd: true,
    subagent: false,
  },
  hookConfig: {
    configFormat: "pi-extension",
  },
  pidField: "agent_pid",
};
