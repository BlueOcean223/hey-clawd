const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const {
  cleanStaleFiles,
  createTrackedEntry,
  pollFile,
  processLine,
  tracked,
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

test("pollFile caps partial lines and reads large deltas without retaining the whole tail", (t) => {
  tracked.clear();
  t.after(() => tracked.clear());

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "clawd-codex-remote-"));
  const filePath = path.join(
    tempDir,
    "rollout-2026-04-14T00-00-00-019d23d4-f1a9-7633-b9c7-758327137228.jsonl"
  );
  t.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));

  const hugePartial = "x".repeat(70000);
  fs.writeFileSync(
    filePath,
    [
      JSON.stringify({ type: "event_msg", payload: { type: "task_started" } }),
      hugePartial,
    ].join("\n")
  );

  pollFile(filePath, path.basename(filePath));

  const entry = tracked.get(filePath);
  assert.ok(entry);
  assert.equal(entry.lastState, "thinking");
  assert.equal(entry.partial, "");
});
