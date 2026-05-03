import Foundation
import QuartzCore

/// 解析 CSS / SVG `transform` 属性为 `CATransform3D`。
///
/// 仅覆盖资产里实际出现的子集：`translate(X[,Y])`、`translateX/Y(L)`、
/// `scale(X[,Y])`、`scaleX/Y(N)`、`rotate(deg[,cx,cy])`。
/// 不支持的函数（如 matrix / skew）会被静默忽略——避免一处书写错误就让整张 SVG 渲染失败。
enum TransformParser {
    /// 解析入口；空字符串或 `none` 返回 identity。
    /// 多个函数之间按"右乘"语义拼接（与浏览器一致）：写在前面的最先作用。
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

            // CATransform3DConcat(a,b) 在数学上是 b·a；这里把新 transform 放在左边表示它先作用。
            result = CATransform3DConcat(transform, result)
        }

        return result
    }
}

private extension TransformParser {
    /// 一个 `name(args…)` 形式的 transform 调用。
    struct TransformComponent {
        var name: String
        var arguments: [String]
    }

    /// 朴素状态机：跳分隔符 → 读字母作为 name → 读 `(...)` 作为参数。
    /// 用 `depth` 计数兼顾未来可能出现的嵌套（虽然资产里目前没有）。
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

    /// 参数支持逗号或空白分隔，与 SVG / CSS 规范一致。
    static func parseArguments(_ rawValue: String) -> [String] {
        rawValue
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 把已解析的 component 派发到具体的 CATransform3D 构造。
    /// `rotate` 的三参数形式 `rotate(deg, cx, cy)` 模拟 SVG 锚点旋转：
    /// 先平移到原点 → 旋转 → 平移回去。
    static func transform(for component: TransformComponent) -> CATransform3D? {
        switch component.name {
        case "translate":
            guard let x = component.arguments.first.flatMap(parseLength) else {
                return nil
            }

            // 严格拒绝 3+ 参数；写错的 transform 不应"看起来像能工作"。
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
                // `scale(N)` 默认等比，与 CSS spec 行为一致。
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
            // 单参数 `rotate(deg)` 直接返回；带锚点形式继续走平移夹心组合。
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

    /// 接受裸数字或带 `px` 后缀的长度值；其他单位（em/%/vh）一律拒绝——资产里不会出现。
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

    /// scale 是无单位倍数；非数字直接拒绝。
    static func parseScale(_ rawValue: String) -> CGFloat? {
        guard let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return CGFloat(value)
    }

    /// 仅支持 deg；CSS 的 turn/rad/grad 都不在资产里使用。最后转弧度返回，CATransform3D 需要弧度。
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

    /// 跨过 SVG 允许的"分隔符"——空白或单个逗号。
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
