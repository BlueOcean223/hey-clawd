import Foundation
import CoreGraphics

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

    private static func parseHexColor(_ colorString: String) -> CGColor? {
        let hex = String(colorString.dropFirst())
        let expandedHex: String

        switch hex.count {
        case 3:
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
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        }

        return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func parseRGBAColor(_ colorString: String) -> CGColor? {
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

    private static func logWarning(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else {
            return
        }

        FileHandle.standardError.write(data)
    }
}
