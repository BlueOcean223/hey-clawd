# 权限匹配键规约

本算法为 Claude Code 的 `PostToolUse` / `PostToolUseFailure` / `PostToolBatch` 事件提供唯一匹配键，使终端侧已处理的工具调用能精确关闭对应的待决权限气泡。

## 算法

1. 对 `tool_input` JSON 值做规范化（canonicalize）。
2. 对规范化结果的 UTF-8 字节计算 `SHA-256`。
3. 输出形如：

```text
sha256:v1:<64 位小写十六进制>
```

只对 `tool_input` 哈希，不包括 hook 外层 payload。

## 规范化 JSON

- 对象的 key 按字典序排列。
- 数组保留原始顺序。
- 字符串使用以下转义子集：`\"`、`\\`、`\b`、`\f`、`\n`、`\r`、`\t`。
- 其它低于 `0x20` 的控制字符使用 `\u00XX` 形式转义。
- 其它字符串内容按 UTF-8 原样输出。
- 整数不带 `.0`。
- 数字无尾随零。
- 浮点数使用最短可往返的 double 字符串：
  - JavaScript：`Number.prototype.toString`。
  - Swift：`String(value)`（针对 `Double`）。
- `null`、`true`、`false` 输出为 JSON 字面量。
- `NaN` 与无穷大视为非法。

## 适用范围

本算法只是 Claude Code 权限事件尚未提供稳定工具请求标识符时的兼容层。仅当一个终端侧工具事件唯一对应一个待决气泡时，才允许它驱动该气泡的关闭。

## 退役条件

当 Claude Code 把 `tool_use_id` 加入 `PermissionRequest` 后，本算法整体作废，应当直接删除而非升级。

## 工作示例

输入：

```json
{"a":{"y":1,"x":2}}
```

规范化后：

```json
{"a":{"x":2,"y":1}}
```

哈希：

```text
sha256:v1:d95ad15e032316bdf90635228caccf4b95c2395260f964e7821de6b278d76584
```
