import Foundation
import CoreGraphics

/// 把 SVG/CSS 颜色字符串解析成 `CGColor`。
///
/// 仅支持当前 `Resources/svg/clawd-*.svg` 实际用到的写法：命名色（black/white/transparent/none）、
/// `#RGB` / `#RRGGBB` / `#RRGGBBAA` 十六进制、以及 `rgba(r,g,b,a)`。
/// 解析失败统一回 nil 并向 stderr 打 warning，方便美术资产更新时尽早暴露问题。
enum ColorParser {
    static func parse(_ colorString: String?) -> CGColor? {
        guard let colorString else {
            return nil
        }

        let trimmed = colorString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logWarning("ColorParser: failed to parse color (empty string)")
            return nil
        }

        let normalized = trimmed.lowercased()

        // 命名色快路径：避开正则和数值解析，覆盖资产里 90% 的 fill/stroke。
        switch normalized {
        case "black":
            return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case "white":
            return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case "transparent", "none":
            return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        default:
            break
        }

        if normalized.hasPrefix("#") {
            return parseHexColor(trimmed)
        }

        if normalized.hasPrefix("rgba("), normalized.hasSuffix(")") {
            return parseRGBAColor(trimmed)
        }

        logWarning("ColorParser: failed to parse color (\(trimmed))")
        return nil
    }

    /// 处理 `#RGB`（每位扩展为 `#RRGGBB`）/ `#RRGGBB` / `#RRGGBBAA` 三种长度。
    private static func parseHexColor(_ colorString: String) -> CGColor? {
        let hex = String(colorString.dropFirst())
        let expandedHex: String

        switch hex.count {
        case 3:
            // `#abc` → `#aabbcc`，与浏览器/SVG 规范一致。
            expandedHex = hex.reduce(into: "") { partialResult, character in
                partialResult.append(character)
                partialResult.append(character)
            }
        case 6, 8:
            expandedHex = hex
        default:
            logWarning("ColorParser: failed to parse hex color (\(colorString))")
            return nil
        }

        guard let value = UInt64(expandedHex, radix: 16) else {
            logWarning("ColorParser: failed to parse hex color (\(colorString))")
            return nil
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if expandedHex.count == 6 {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 1
        } else {
            // 8 位长度：低字节是 alpha，符合 CSS Color 4 / SVG2 的次序。
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        }

        return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// `rgba(r,g,b,a)` 严格四参数解析；rgb 整数范围 0-255、alpha 浮点范围 0-1，越界一律拒绝。
    private static func parseRGBAColor(_ colorString: String) -> CGColor? {
        // 跳过前缀 "rgba(" 和末尾 ")"，只剩中间的逗号分隔参数。
        let startIndex = colorString.index(colorString.startIndex, offsetBy: 5)
        let endIndex = colorString.index(before: colorString.endIndex)
        let content = colorString[startIndex..<endIndex]
        let components = content
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard components.count == 4,
              let redValue = Int(components[0]),
              let greenValue = Int(components[1]),
              let blueValue = Int(components[2]),
              let alphaValue = Double(components[3]),
              (0...255).contains(redValue),
              (0...255).contains(greenValue),
              (0...255).contains(blueValue),
              alphaValue >= 0,
              alphaValue <= 1 else {
            logWarning("ColorParser: failed to parse rgba color (\(colorString))")
            return nil
        }

        return CGColor(
            srgbRed: CGFloat(redValue) / 255,
            green: CGFloat(greenValue) / 255,
            blue: CGFloat(blueValue) / 255,
            alpha: CGFloat(alphaValue)
        )
    }

    /// 用 stderr 而非 `print` 打 warning，方便测试和构建脚本捕获。
    private static func logWarning(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else {
            return
        }

        FileHandle.standardError.write(data)
    }
}
