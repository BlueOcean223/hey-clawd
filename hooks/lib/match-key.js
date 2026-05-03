const crypto = require("crypto");

function canonicalize(value) {
  if (value === null) return "null";

  if (Array.isArray(value)) {
    return `[${value.map(canonicalize).join(",")}]`;
  }

  switch (typeof value) {
    case "string":
      return `"${escapeString(value)}"`;
    case "number":
      if (!Number.isFinite(value)) {
        throw new Error("Cannot canonicalize NaN or Infinity");
      }
      return value.toString();
    case "boolean":
      return value ? "true" : "false";
    case "object": {
      const keys = Object.keys(value).sort();
      const entries = keys.map((key) => `${canonicalize(key)}:${canonicalize(value[key])}`);
      return `{${entries.join(",")}}`;
    }
    default:
      throw new Error(`Unsupported JSON value: ${typeof value}`);
  }
}

function hashToolInput(value) {
  const digest = crypto
    .createHash("sha256")
    .update(canonicalize(value), "utf8")
    .digest("hex");
  return `sha256:v1:${digest}`;
}

function escapeString(value) {
  let out = "";
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    switch (code) {
      case 0x22:
        out += '\\"';
        break;
      case 0x5c:
        out += "\\\\";
        break;
      case 0x08:
        out += "\\b";
        break;
      case 0x0c:
        out += "\\f";
        break;
      case 0x0a:
        out += "\\n";
        break;
      case 0x0d:
        out += "\\r";
        break;
      case 0x09:
        out += "\\t";
        break;
      default:
        if (code < 0x20) {
          out += `\\u${code.toString(16).padStart(4, "0")}`;
        } else {
          out += value[i];
        }
    }
  }
  return out;
}

module.exports = { canonicalize, hashToolInput };
