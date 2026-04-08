const test = require("node:test");
const assert = require("node:assert/strict");

const {
  cleanStaleFiles,
  createTrackedEntry,
  processLine,
} = require("../codex-remote-monitor");

function emitCollector() {
  const events = [];
  return {
    events,
    emit(sessionId, state, event, cwd) {
      events.push({ sessionId, state, event, cwd });
    },
  };
}

test("keeps tool-use completion as attention even if another user_message arrives mid-turn", () => {
  const entry = createTrackedEntry("codex:test");
  const { events, emit } = emitCollector();

  processLine(JSON.stringify({ type: "event_msg", payload: { type: "task_started" } }), entry, emit);
  processLine(JSON.stringify({ type: "response_item", payload: { type: "function_call" } }), entry, emit);
  processLine(JSON.stringify({ type: "event_msg", payload: { type: "user_message" } }), entry, emit);
  processLine(JSON.stringify({ type: "event_msg", payload: { type: "task_complete" } }), entry, emit);

  assert.deepEqual(
    events.map(({ state, event }) => ({ state, event })),
    [
      { state: "thinking", event: "event_msg:task_started" },
      { state: "working", event: "response_item:function_call" },
      { state: "thinking", event: "event_msg:user_message" },
      { state: "attention", event: "event_msg:task_complete" },
    ]
  );
  assert.equal(entry.hadToolUse, false);
});

test("treats agent_message as activity so stale cleanup does not cut off long text-only turns", () => {
  const originalNow = Date.now;
  const entry = createTrackedEntry("codex:test");
  const tracked = new Map([["/tmp/rollout.jsonl", entry]]);
  const { events, emit } = emitCollector();

  try {
    let now = 1_000_000;
    Date.now = () => now;

    entry.lastEventTime = now - 301_000;
    processLine(JSON.stringify({ type: "event_msg", payload: { type: "agent_message" } }), entry, emit);

    now += 1_000;
    cleanStaleFiles(tracked, emit);

    assert.equal(events.length, 0);
    assert.equal(tracked.size, 1);
    assert.equal(entry.lastEventTime, 1_000_000);
  } finally {
    Date.now = originalNow;
  }
});
