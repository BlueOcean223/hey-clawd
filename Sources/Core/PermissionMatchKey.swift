import CryptoKit
import Foundation

/// 把 PermissionRequest 的 `tool_input` 标准化后哈希成稳定 key。
///
/// 用途：当 BubbleStack 中已有同一工具 + 同一参数的待决气泡时，新进来的请求需要
/// "认领" 上一条气泡的决定，而不是再弹一条。这要求 Swift 端与 Node hook 端
/// 计算出**完全一致**的哈希——因此本类的格式必须 1:1 对齐 hook/clawd-hook.js
/// 中的 `canonicalize` 实现，包括：
/// - dictionary key 字典序排序
/// - 空白/转义字符使用 JSON 子集（`\b\f\n\r\t` + `\u00xx`）
/// - 数字按 JS Number 行为输出（IEEE-754 + JS `Number.toString` 可读形态）
///
/// **任何修改都必须同步两端，并补充测试**。
enum PermissionMatchKey {
    /// JS 安全整数边界 (Number.MAX_SAFE_INTEGER / MIN_SAFE_INTEGER)。
    /// 超过这个范围的整数 hook 端 `JSON.parse` 会精度损失，因此我们也走 double 序列化。
    private static let maxJavaScriptSafeInteger: UInt64 = 9_007_199_254_740_991
    private static let minJavaScriptSafeInteger: Int64 = -9_007_199_254_740_991

    static func canonicalize(_ value: Any) -> Data {
        guard let canonical = try? canonicalString(value) else {
            return Data()
        }
        return Data(canonical.utf8)
    }

    /// `canonicalize` + SHA-256 + 固定前缀 `sha256:v1:` 作为 BubbleStack 的对外 key。
    static func hashToolInput(_ value: Any) -> String {
        hash(canonicalize(value))
    }

    /// 直接给一段未解析的 JSON 字节计算 key；解析失败返回 nil。
    /// 主要服务于 HTTP 路径，避免再做一次 NSData → Any → NSData 来回。
    static func hashRawJSON(_ data: Data) -> String? {
        guard
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let canonical = try? canonicalString(value)
        else {
            return nil
        }

        return hash(Data(canonical.utf8))
    }

    private static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        // 前缀 `v1` 留给未来格式升级；hook 端见 `MATCH_KEY_VERSION`。
        return "sha256:v1:\(hex)"
    }

    /// 递归把任意 JSON 兼容值序列化为 canonical 字符串。
    /// 注意 `NSDictionary` / `NSArray` 分支：JSONSerialization 在某些路径上会返回 ObjC 容器，
    /// 这里手动转换以便统一走 Swift Collection 实现。
    private static func canonicalString(_ value: Any) throws -> String {
        if value is NSNull {
            return "null"
        }

        if let array = value as? [Any] {
            return try canonicalArray(array)
        }

        if let array = value as? NSArray {
            return try canonicalArray(array.map { $0 })
        }

        if let dictionary = value as? [String: Any] {
            return try canonicalDictionary(dictionary)
        }

        if let dictionary = value as? NSDictionary {
            var normalized: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else {
                    throw CanonicalizationError.unsupportedValue
                }
                normalized[key] = value
            }
            return try canonicalDictionary(normalized)
        }

        if let string = value as? String {
            return "\"\(escapeString(string))\""
        }

        if let number = value as? NSNumber {
            return try canonicalNumber(number)
        }

        throw CanonicalizationError.unsupportedValue
    }

    private static func canonicalArray(_ array: [Any]) throws -> String {
        let values = try array.map { try canonicalString($0) }
        return "[\(values.joined(separator: ","))]"
    }

    /// dictionary 必须按 key 字典序排序输出，hook 端 `Object.keys().sort()` 完全一致。
    private static func canonicalDictionary(_ dictionary: [String: Any]) throws -> String {
        let entries = try dictionary.keys.sorted().map { key in
            let value = dictionary[key] ?? NSNull()
            return "\"\(escapeString(key))\":\(try canonicalString(value))"
        }
        return "{\(entries.joined(separator: ","))}"
    }

    /// NSNumber 携带的 ObjCType 决定走哪条路径：bool / 有符号整数 / 无符号整数 / 浮点。
    /// 关键 invariant：所有路径最终都要与 JS `Number.toString()` 输出对齐。
    private static func canonicalNumber(_ number: NSNumber) throws -> String {
        // CFBoolean 在 64 位上和 NSNumber 共享 Bridge；用 type id 判断比 `isKind(of:)` 可靠。
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }

        let objCType = String(cString: number.objCType)
        switch objCType {
        case "c", "s", "i", "l", "q", "B":
            let value = number.int64Value
            if value >= minJavaScriptSafeInteger && value <= Int64(maxJavaScriptSafeInteger) {
                return "\(value)"
            }
            // The Node hook receives JSON through JSON.parse, so unsafe integers
            // have already been rounded to JavaScript Number values.
            return try canonicalJSNumber(number.doubleValue)
        case "C", "S", "I", "L", "Q":
            let value = number.uint64Value
            if value <= maxJavaScriptSafeInteger {
                return "\(value)"
            }
            // Avoid int64Value wraparound for uint64 JSON values and match Node.
            return try canonicalJSNumber(number.doubleValue)
        default:
            return try canonicalJSNumber(number.doubleValue)
        }
    }

    /// 模拟 JS `Number.prototype.toString()`：
    /// NaN/Infinity 不允许（hook 端 JSON.stringify 也会拒绝），0 单独输出避免出 "-0"。
    private static func canonicalJSNumber(_ value: Double) throws -> String {
        guard value.isFinite else {
            throw CanonicalizationError.unsupportedValue
        }
        if value == 0 {
            return "0"
        }

        return canonicalDouble(value)
    }

    /// Swift 默认输出常用 "1.0e+20" 这种带 `E` 的形式；JS 用 `e`。
    /// 同时 JS 在绝对值 ∈ [1e-6, 1e21) 时用十进制小数展开，而非科学计数法——这里复刻该规则。
    private static func canonicalDouble(_ value: Double) -> String {
        let rendered = String(value).replacingOccurrences(of: "E", with: "e")
        guard rendered.contains("e") else {
            return trimTrailingFractionZeros(rendered)
        }

        let normalizedExponent = normalizedExponentString(rendered)
        let absoluteValue = abs(value)
        if absoluteValue >= 1e-6 && absoluteValue < 1e21 {
            return decimalNotation(fromExponentString: normalizedExponent)
        }

        return normalizedExponent
    }

    /// 把 "1.5e20" / "1.5e-7" 规范成 JS 形态："1.5e+20" / "1.5e-7"。
    /// JS 输出在指数 ≥ 0 时强制带 `+` 号。
    private static func normalizedExponentString(_ rendered: String) -> String {
        let parts = rendered.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let exponent = Int(parts[1]) else {
            return rendered
        }

        let mantissa = trimTrailingFractionZeros(String(parts[0]))
        let sign = exponent >= 0 ? "+" : "-"
        return "\(mantissa)e\(sign)\(abs(exponent))"
    }

    /// 把指数形式还原为十进制小数（JS 在中等量级时的实际输出）。
    /// 算法：把所有有效数字拼成纯数字串，再按 `decimalIndex` 位置插入小数点。
    private static func decimalNotation(fromExponentString rendered: String) -> String {
        let parts = rendered.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let exponent = Int(parts[1]) else {
            return trimTrailingFractionZeros(rendered)
        }

        var mantissa = String(parts[0])
        var sign = ""
        if mantissa.hasPrefix("-") {
            sign = "-"
            mantissa.removeFirst()
        } else if mantissa.hasPrefix("+") {
            mantissa.removeFirst()
        }

        let mantissaParts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = String(mantissaParts.first ?? "")
        let fractionPart = mantissaParts.count > 1 ? String(mantissaParts[1]) : ""
        let digits = integerPart + fractionPart
        let decimalIndex = integerPart.count + exponent

        let decimal: String
        if decimalIndex <= 0 {
            // 纯小数：前置 "0." + 若干个 "0"（指数值的负数部分）+ 有效数字。
            decimal = "0." + String(repeating: "0", count: -decimalIndex) + digits
        } else if decimalIndex >= digits.count {
            // 纯整数：在末尾补足 "0" 让小数点正好落在末位之后。
            decimal = digits + String(repeating: "0", count: decimalIndex - digits.count)
        } else {
            let splitIndex = digits.index(digits.startIndex, offsetBy: decimalIndex)
            decimal = String(digits[..<splitIndex]) + "." + String(digits[splitIndex...])
        }

        return sign + trimTrailingFractionZeros(decimal)
    }

    /// "1.500" → "1.5"，"1." → "1"。JS 不会输出尾部 0 或孤立小数点。
    private static func trimTrailingFractionZeros(_ value: String) -> String {
        guard value.contains(".") else {
            return value
        }

        var rendered = value
        while rendered.hasSuffix("0") {
            rendered.removeLast()
        }
        if rendered.hasSuffix(".") {
            rendered.removeLast()
        }
        return rendered
    }

    /// 严格按 JSON spec 转义字符串：保留可见 ASCII，控制字符用 `\uXXXX`。
    /// 注意必须迭代 `unicodeScalars` 而非 `Character`，否则 emoji 等组合字符会被拆错。
    private static func escapeString(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                output += "\\\""
            case 0x5c:
                output += "\\\\"
            case 0x08:
                output += "\\b"
            case 0x0c:
                output += "\\f"
            case 0x0a:
                output += "\\n"
            case 0x0d:
                output += "\\r"
            case 0x09:
                output += "\\t"
            case 0x00..<0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output += String(scalar)
            }
        }
        return output
    }

    private enum CanonicalizationError: Error {
        case unsupportedValue
    }
}
