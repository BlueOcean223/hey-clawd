"use strict";

function parseMode(argv = process.argv) {
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "-p" || arg === "--print") return "print";
    if (arg === "--mode") {
      const next = argv[i + 1];
      if (next === "json") return "json";
      if (next === "rpc") return "rpc";
    }
    if (arg === "--mode=json") return "json";
    if (arg === "--mode=rpc") return "rpc";
  }
  return "interactive";
}

function isInteractiveMode(runtime = {}) {
  const argv = runtime.argv ?? process.argv;
  const stdinIsTTY = runtime.stdinIsTTY ?? !!process.stdin.isTTY;
  const stdoutIsTTY = runtime.stdoutIsTTY ?? !!process.stdout.isTTY;
  return parseMode(argv) === "interactive" && stdinIsTTY && stdoutIsTTY;
}

function shouldReport(ctx, runtime) {
  if (typeof ctx?.hasUI === "boolean") return ctx.hasUI;
  if (ctx !== undefined) return false;
  return isInteractiveMode(runtime);
}

function buildPayload({ state, event, ctx = {}, metadata, agentPid = process.pid }) {
  const rawSessionId = ctx.sessionManager?.getSessionId?.() || "default";
  const sessionId = rawSessionId.trim() || "default";
  const payload = {
    state,
    session_id: `pi:${sessionId}`,
    event,
    agent_id: "pi",
    agent_pid: agentPid,
  };

  if (ctx.cwd) payload.cwd = ctx.cwd;
  if (metadata?.sourcePid) payload.source_pid = metadata.sourcePid;
  if (metadata?.editor) payload.editor = metadata.editor;
  return payload;
}

function attach(pi, deps) {
  const { shouldReport, buildPayload, postState } = deps;
  const deliveryChains = new Map();

  const queueDelivery = (payload) => {
    const sessionId = payload.session_id || "pi:default";
    const previous = deliveryChains.get(sessionId) || Promise.resolve();
    const next = previous
      .then(() => postState(payload), () => postState(payload))
      .then(() => undefined, () => undefined);
    deliveryChains.set(sessionId, next);
    next.finally(() => {
      if (deliveryChains.get(sessionId) === next) deliveryChains.delete(sessionId);
    });
    return next;
  };

  const send = (state, event, ctx, awaitDelivery = false) => {
    const promise = queueDelivery(buildPayload(state, event, ctx));
    if (awaitDelivery) return promise;
    void promise;
  };

  pi.on("session_start", async (_evt, ctx) => {
    if (!shouldReport(ctx)) return;
    send("idle", "SessionStart", ctx);
  });

  pi.on("before_agent_start", async (_evt, ctx) => {
    if (!shouldReport(ctx)) return;
    send("thinking", "UserPromptSubmit", ctx);
  });

  pi.on("tool_call", async (_evt, ctx) => {
    if (!shouldReport(ctx)) return;
    send("working", "PreToolUse", ctx);
  });

  pi.on("tool_result", async (evt, ctx) => {
    if (!shouldReport(ctx)) return;
    send("working", evt?.isError ? "PostToolUseFailure" : "PostToolUse", ctx);
  });

  pi.on("agent_end", async (_evt, ctx) => {
    if (!shouldReport(ctx)) return;
    await send("attention", "Stop", ctx, true);
  });

  pi.on("session_before_compact", async (_evt, ctx) => {
    if (!shouldReport(ctx)) return;
    send("sweeping", "PreCompact", ctx);
  });

  pi.on("session_compact", async (_evt, ctx) => {
    if (!shouldReport(ctx)) return;
    send("attention", "PostCompact", ctx);
  });

  pi.on("session_shutdown", async (_evt, ctx) => {
    if (!shouldReport(ctx)) return;
    await send("sleeping", "SessionEnd", ctx, true);
  });
}

module.exports = {
  parseMode,
  isInteractiveMode,
  shouldReport,
  buildPayload,
  attach,
};
