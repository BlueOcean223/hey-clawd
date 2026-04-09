import Foundation
import QuartzCore

enum TransformParser {
    static func parse(_ value: String) -> CATransform3D {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else {
            return CATransform3DIdentity
        }

        var result = CATransform3DIdentity

        for component in components(in: trimmed) {
            guard let transform = transform(for: component) else {
                continue
            }

            result = CATransform3DConcat(transform, result)
        }

        return result
    }
}

private extension TransformParser {
    struct TransformComponent {
        var name: String
        var arguments: [String]
    }

    static func components(in source: String) -> [TransformComponent] {
        var result: [TransformComponent] = []
        var index = source.startIndex

        while index < source.endIndex {
            skipSeparators(in: source, index: &index)
            guard index < source.endIndex else {
                break
            }

            let nameStart = index
            while index < source.endIndex, source[index].isLetter {
                source.formIndex(after: &index)
            }

            guard nameStart < index else {
                source.formIndex(after: &index)
                continue
            }

            let name = String(source[nameStart..<index]).lowercased()
            skipWhitespace(in: source, index: &index)

            guard index < source.endIndex, source[index] == "(" else {
                continue
            }

            source.formIndex(after: &index)
            let argumentsStart = index
            var depth = 1

            while index < source.endIndex, depth > 0 {
                switch source[index] {
                case "(":
                    depth += 1
                case ")":
                    depth -= 1
                default:
                    break
                }

                if depth == 0 {
                    let rawArguments = String(source[argumentsStart..<index])
                    result.append(
                        TransformComponent(
                            name: name,
                            arguments: parseArguments(rawArguments)
                        )
                    )
                }

                source.formIndex(after: &index)
            }
        }

        return result
    }

    static func parseArguments(_ rawValue: String) -> [String] {
        rawValue
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func transform(for component: TransformComponent) -> CATransform3D? {
        switch component.name {
        case "translate":
            guard let x = component.arguments.first.flatMap(parseLength) else {
                return nil
            }

            if component.arguments.count > 2 {
                return nil
            }

            let y: CGFloat
            if component.arguments.count == 2 {
                guard let parsedY = parseLength(component.arguments[1]) else {
                    return nil
                }
                y = parsedY
            } else {
                y = 0
            }

            return CATransform3DMakeTranslation(x, y, 0)

        case "translatex":
            guard component.arguments.count == 1,
                  let x = parseLength(component.arguments[0]) else {
                return nil
            }

            return CATransform3DMakeTranslation(x, 0, 0)

        case "translatey":
            guard component.arguments.count == 1,
                  let y = parseLength(component.arguments[0]) else {
                return nil
            }

            return CATransform3DMakeTranslation(0, y, 0)

        case "scale":
            guard let x = component.arguments.first.flatMap(parseScale) else {
                return nil
            }

            if component.arguments.count > 2 {
                return nil
            }

            let y: CGFloat
            if component.arguments.count == 2 {
                guard let parsedY = parseScale(component.arguments[1]) else {
                    return nil
                }
                y = parsedY
            } else {
                y = x
            }

            return CATransform3DMakeScale(x, y, 1)

        case "scalex":
            guard component.arguments.count == 1,
                  let x = parseScale(component.arguments[0]) else {
                return nil
            }

            return CATransform3DMakeScale(x, 1, 1)

        case "scaley":
            guard component.arguments.count == 1,
                  let y = parseScale(component.arguments[0]) else {
                return nil
            }

            return CATransform3DMakeScale(1, y, 1)

        case "rotate":
            guard let angle = component.arguments.first.flatMap(parseAngle) else {
                return nil
            }

            let rotation = CATransform3DMakeRotation(angle, 0, 0, 1)
            guard component.arguments.count == 3,
                  let cx = parseLength(component.arguments[1]),
                  let cy = parseLength(component.arguments[2]) else {
                return rotation
            }

            let translateToOrigin = CATransform3DMakeTranslation(-cx, -cy, 0)
            let translateBack = CATransform3DMakeTranslation(cx, cy, 0)
            return CATransform3DConcat(CATransform3DConcat(translateToOrigin, rotation), translateBack)

        default:
            return nil
        }
    }

    static func parseLength(_ rawValue: String) -> CGFloat? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let normalized = trimmed.lowercased()
        let numberPortion: Substring
        if normalized.hasSuffix("px") {
            numberPortion = normalized.dropLast(2)
        } else {
            numberPortion = Substring(normalized)
        }

        guard let value = Double(numberPortion.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return CGFloat(value)
    }

    static func parseScale(_ rawValue: String) -> CGFloat? {
        guard let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return CGFloat(value)
    }

    static func parseAngle(_ rawValue: String) -> CGFloat? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let normalized = trimmed.lowercased()
        let numberPortion: Substring
        if normalized.hasSuffix("deg") {
            numberPortion = normalized.dropLast(3)
        } else {
            numberPortion = Substring(normalized)
        }

        guard let degrees = Double(numberPortion.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return CGFloat(degrees) * .pi / 180
    }

    static func skipSeparators(in source: String, index: inout String.Index) {
        while index < source.endIndex,
              (source[index].isWhitespace || source[index] == ",") {
            source.formIndex(after: &index)
        }
    }

    static func skipWhitespace(in source: String, index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace {
            source.formIndex(after: &index)
        }
    }
}
