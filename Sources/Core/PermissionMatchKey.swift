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

        var rendered = String(value)
        if rendered.hasSuffix(".0") {
            rendered.removeLast(2)
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
