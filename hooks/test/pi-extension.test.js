const test = require("node:test");
const assert = require("node:assert/strict");

const {
  parseMode,
  isInteractiveMode,
  shouldReport,
  buildPayload,
  attach,
} = require("../pi-extension-core");

test("parseMode returns interactive for plain pi argv", () => {
  assert.equal(parseMode(["node", "pi"]), "interactive");
});

test("parseMode detects print mode flags", () => {
  assert.equal(parseMode(["node", "pi", "-p"]), "print");
  assert.equal(parseMode(["node", "pi", "--print"]), "print");
});

test("parseMode detects json and rpc modes across argv variants", () => {
  assert.equal(parseMode(["node", "pi", "--mode", "json"]), "json");
  assert.equal(parseMode(["node", "pi", "--mode=rpc"]), "rpc");
  assert.equal(parseMode(["node", "pi", "--foo", "bar", "--mode", "json", "--verbose"]), "json");
});

test("isInteractiveMode requires interactive argv and tty", () => {
  assert.equal(isInteractiveMode({ argv: ["node", "pi"], stdinIsTTY: true, stdoutIsTTY: true }), true);
  assert.equal(isInteractiveMode({ argv: ["node", "pi", "--mode", "json"], stdinIsTTY: true, stdoutIsTTY: true }), false);
  assert.equal(isInteractiveMode({ argv: ["node", "pi"], stdinIsTTY: true, stdoutIsTTY: false }), false);
});

test("shouldReport prefers ctx.hasUI when present", () => {
  assert.equal(shouldReport({ hasUI: true }), true);
  assert.equal(shouldReport({ hasUI: false }), false);
});

test("shouldReport falls back to interactive mode when ctx lacks hasUI", () => {
  assert.equal(
    shouldReport({}, { argv: ["node", "pi"], stdinIsTTY: true, stdoutIsTTY: true }),
    true
  );
  assert.equal(
    shouldReport({}, { argv: ["node", "pi", "--mode", "json"], stdinIsTTY: true, stdoutIsTTY: true }),
    false
  );
});

test("shouldReport falls back to interactive mode only when ctx is missing", () => {
  assert.equal(
    shouldReport(undefined, { argv: ["node", "pi"], stdinIsTTY: true, stdoutIsTTY: true }),
    true
  );
  assert.equal(
    shouldReport(undefined, { argv: ["node", "pi", "--print"], stdinIsTTY: true, stdoutIsTTY: true }),
    false
  );
});

test("buildPayload includes session prefix and optional fields when present", () => {
  const payload = buildPayload({
    state: "working",
    event: "PreToolUse",
    ctx: {
      cwd: "/tmp/project",
      sessionManager: {
        getSessionId: () => "abc123",
      },
    },
    metadata: {
      sourcePid: 12345,
      editor: "cursor",
    },
    agentPid: 23456,
  });

  assert.deepEqual(payload, {
    state: "working",
    session_id: "pi:abc123",
    event: "PreToolUse",
    cwd: "/tmp/project",
    agent_id: "pi",
    agent_pid: 23456,
    source_pid: 12345,
    editor: "cursor",
  });
});

test("buildPayload omits cwd and metadata when absent", () => {
  const payload = buildPayload({
    state: "attention",
    event: "Stop",
    ctx: {
      sessionManager: {
        getSessionId: () => "   ",
      },
    },
    agentPid: 99,
  });

  assert.deepEqual(payload, {
    state: "attention",
    session_id: "pi:default",
    event: "Stop",
    agent_id: "pi",
    agent_pid: 99,
  });
});

function makeFakePi() {
  const handlers = {};
  const posted = [];
  return {
    pi: {
      on(name, fn) {
        handlers[name] = fn;
      },
    },
    handlers,
    posted,
    async emit(name, event, ctx) {
      if (handlers[name]) await handlers[name](event, ctx);
    },
  };
}

function makeDeferred() {
  let resolve;
  const promise = new Promise((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

test("agent_end 发 Stop", async () => {
  const { pi, posted, emit } = makeFakePi();
  attach(pi, {
    shouldReport: () => true,
    buildPayload: (state, event) => ({ state, event }),
    postState: async (payload) => {
      posted.push(payload);
      return true;
    },
  });

  await emit("before_agent_start", {}, { hasUI: true });
  await emit("agent_end", {}, { hasUI: true });

  const stops = posted.filter((payload) => payload.event === "Stop");
  assert.equal(stops.length, 1);
  assert.equal(stops[0].state, "attention");
});

test("agent_end 会等待 Stop 投递完成", async () => {
  const { pi, emit } = makeFakePi();
  const delivery = makeDeferred();
  let delivered = false;
  attach(pi, {
    shouldReport: () => true,
    buildPayload: (state, event) => ({ state, event }),
    postState: async () => {
      await delivery.promise;
      delivered = true;
      return true;
    },
  });

  const emitPromise = emit("agent_end", {}, { hasUI: true });
  await Promise.resolve();

  assert.equal(delivered, false, "postState 未完成前 agent_end 不应提前返回");

  delivery.resolve();
  await emitPromise;

  assert.equal(delivered, true);
});

test("session_shutdown 会等待同 session 更早的状态投递完成", async () => {
  const { pi, emit } = makeFakePi();
  const toolResultDelivery = makeDeferred();
  const events = [];
  attach(pi, {
    shouldReport: () => true,
    buildPayload: (_state, event, ctx) => ({
      event,
      session_id: `pi:${ctx.sessionId}`,
    }),
    postState: async (payload) => {
      events.push(`start:${payload.event}`);
      if (payload.event === "PostToolUse") await toolResultDelivery.promise;
      events.push(`end:${payload.event}`);
      return true;
    },
  });

  await emit("tool_result", { isError: false }, { hasUI: true, sessionId: "same" });
  const shutdownPromise = emit("session_shutdown", {}, { hasUI: true, sessionId: "same" });
  await Promise.resolve();

  assert.deepEqual(events, ["start:PostToolUse"], "SessionEnd 不应抢在更早状态前面开始投递");

  toolResultDelivery.resolve();
  await shutdownPromise;

  assert.deepEqual(events, [
    "start:PostToolUse",
    "end:PostToolUse",
    "start:SessionEnd",
    "end:SessionEnd",
  ]);
});

test("不同 session 的投递彼此不阻塞", async () => {
  const { pi, emit } = makeFakePi();
  const toolResultDelivery = makeDeferred();
  const events = [];
  attach(pi, {
    shouldReport: () => true,
    buildPayload: (_state, event, ctx) => ({
      event,
      session_id: `pi:${ctx.sessionId}`,
    }),
    postState: async (payload) => {
      events.push(`start:${payload.session_id}:${payload.event}`);
      if (payload.session_id === "pi:a" && payload.event === "PostToolUse") await toolResultDelivery.promise;
      events.push(`end:${payload.session_id}:${payload.event}`);
      return true;
    },
  });

  await emit("tool_result", { isError: false }, { hasUI: true, sessionId: "a" });
  const shutdownPromise = emit("session_shutdown", {}, { hasUI: true, sessionId: "b" });
  await shutdownPromise;

  assert.deepEqual(events, [
    "start:pi:a:PostToolUse",
    "start:pi:b:SessionEnd",
    "end:pi:b:SessionEnd",
  ]);

  toolResultDelivery.resolve();
});

test("多 turn 场景 turn_end 不提前发 Stop", async () => {
  const { pi, posted, emit } = makeFakePi();
  attach(pi, {
    shouldReport: () => true,
    buildPayload: (state, event) => ({ state, event }),
    postState: async (payload) => {
      posted.push(payload);
      return true;
    },
  });

  await emit("before_agent_start", {}, { hasUI: true });
  await emit("tool_call", {}, { hasUI: true });
  await emit("tool_result", {}, { hasUI: true });
  await emit("turn_end", {}, { hasUI: true });

  assert.equal(
    posted.filter((payload) => payload.event === "Stop").length,
    0,
    "turn_end 不应触发 Stop"
  );

  await emit("agent_end", {}, { hasUI: true });

  const stops = posted.filter((payload) => payload.event === "Stop");
  assert.equal(stops.length, 1, "agent_end 前后 Stop 只发一次");
});

test("shouldReport=false 时 attach 不 postState", async () => {
  const { pi, posted, emit } = makeFakePi();
  attach(pi, {
    shouldReport: () => false,
    buildPayload: (state, event) => ({ state, event }),
    postState: async (payload) => {
      posted.push(payload);
      return true;
    },
  });

  await emit("before_agent_start", {}, { hasUI: false });
  await emit("tool_call", {}, { hasUI: false });
  await emit("tool_result", {}, { hasUI: false });
  await emit("agent_end", {}, { hasUI: false });
  await emit("session_shutdown", {}, { hasUI: false });

  assert.equal(posted.length, 0);
});
