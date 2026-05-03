import CryptoKit
import Foundation

enum PermissionMatchKey {
    static func canonicalize(_ value: Any) -> Data {
        guard let canonical = try? canonicalString(value) else {
            return Data()
        }
        return Data(canonical.utf8)
    }

    static func hashToolInput(_ value: Any) -> String {
        hash(canonicalize(value))
    }

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
        return "sha256:v1:\(hex)"
    }

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

    private static func canonicalDictionary(_ dictionary: [String: Any]) throws -> String {
        let entries = try dictionary.keys.sorted().map { key in
            let value = dictionary[key] ?? NSNull()
            return "\"\(escapeString(key))\":\(try canonicalString(value))"
        }
        return "{\(entries.joined(separator: ","))}"
    }

    private static func canonicalNumber(_ number: NSNumber) throws -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }

        let objCType = String(cString: number.objCType)
        let integerTypes: Set<String> = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q", "B"]
        if integerTypes.contains(objCType) {
            return "\(number.int64Value)"
        }

        let value = number.doubleValue
        guard value.isFinite else {
            throw CanonicalizationError.unsupportedValue
        }
        if value == 0 {
            return "0"
        }

        return canonicalDouble(value)
    }

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

    private static func normalizedExponentString(_ rendered: String) -> String {
        let parts = rendered.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let exponent = Int(parts[1]) else {
            return rendered
        }

        let mantissa = trimTrailingFractionZeros(String(parts[0]))
        let sign = exponent >= 0 ? "+" : "-"
        return "\(mantissa)e\(sign)\(abs(exponent))"
    }

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
            decimal = "0." + String(repeating: "0", count: -decimalIndex) + digits
        } else if decimalIndex >= digits.count {
            decimal = digits + String(repeating: "0", count: decimalIndex - digits.count)
        } else {
            let splitIndex = digits.index(digits.startIndex, offsetBy: decimalIndex)
            decimal = String(digits[..<splitIndex]) + "." + String(digits[splitIndex...])
        }

        return sign + trimTrailingFractionZeros(decimal)
    }

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
