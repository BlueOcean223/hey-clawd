const test = require("node:test");
const assert = require("node:assert/strict");

const { commandLooksLikeGeminiCLI } = require("../gemini-hook");

test("Gemini hook detects node-shebang Gemini CLI command lines", () => {
  assert.equal(
    commandLooksLikeGeminiCLI("/opt/homebrew/opt/node/bin/node /opt/homebrew/Cellar/gemini-cli/0.40.1/bin/gemini"),
    true
  );
  assert.equal(
    commandLooksLikeGeminiCLI("/usr/local/bin/node /Users/me/.npm/_npx/abc/node_modules/@google/gemini-cli/dist/index.js"),
    true
  );
  assert.equal(
    commandLooksLikeGeminiCLI("/usr/local/bin/node /Users/me/code/hey-clawd/hooks/gemini-hook.js"),
    false
  );
});
