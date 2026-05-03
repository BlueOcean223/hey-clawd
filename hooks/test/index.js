const fs = require("node:fs");
const path = require("node:path");

for (const file of fs.readdirSync(__dirname).filter((name) => name.endsWith(".test.js")).sort()) {
  require(path.join(__dirname, file));
}
