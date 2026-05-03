const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const { hashToolInput } = require("../lib/match-key");

const fixtures = require(path.join(
  __dirname,
  "../../Tests/HeyClawdAppTests/Fixtures/match-key-fixtures.json"
));

for (const fx of fixtures) {
  test(`hashes fixture ${fx.name}`, () => {
    assert.equal(hashToolInput(fx.input), fx.expected);
  });
}

test("object key order is stable", () => {
  assert.equal(hashToolInput({ a: 1, b: 2 }), hashToolInput({ b: 2, a: 1 }));
});

test("array order affects the hash", () => {
  assert.notEqual(hashToolInput([1, 2, 3]), hashToolInput([3, 2, 1]));
});

test("empty object hash is stable", () => {
  assert.equal(
    hashToolInput({}),
    "sha256:v1:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
  );
});
