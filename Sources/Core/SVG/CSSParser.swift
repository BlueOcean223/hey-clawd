import Foundation
import CoreGraphics

enum CSSParser {
    struct CSSResult: Sendable {
        var animations: [String: SVGAnimation] = [:]
        var staticStyleBindings: [SVGStaticStyleBinding] = []
        var animationBindings: [SVGAnimationBinding] = []
        var animationStyleBindings: [SVGAnimationStyleBinding] = []
        var transitions: [SVGTransitionBinding] = []
    }

    static let defaultTimingFunction: TimingFunction = .cubicBezier(0.25, 0.1, 0.25, 1)

    static func parse(_ styleBlocks: [String]) -> CSSResult {
        let combined = stripComments(styleBlocks.joined(separator: "\n"))
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CSSResult()
        }

        var result = CSSResult()
        let characters = Array(combined)
        var index = 0

        while true {
            index = skipIgnorable(characters, from: index)
            guard index < characters.count else {
                break
            }

            if characters[index] == "@" {
                guard let braceIndex = findNextTopLevel(in: characters, target: "{", start: index),
                      let block = readBalancedBlock(in: characters, openBraceIndex: braceIndex)
                else {
                    break
                }

                let prelude = trimmedString(from: characters, start: index, end: braceIndex)
                if prelude.lowercased().hasPrefix("@keyframes") {
                    let name = prelude.dropFirst("@keyframes".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        let animation = parseKeyframes(name: name, body: String(characters[block.contentRange]))
                        result.animations[name] = animation
                    }
                }

                index = block.endIndex + 1
                continue
            }

            guard let braceIndex = findNextTopLevel(in: characters, target: "{", start: index),
                  let block = readBalancedBlock(in: characters, openBraceIndex: braceIndex)
            else {
                break
            }

            let selectorText = trimmedString(from: characters, start: index, end: braceIndex)
            let declarations = parseDeclarations(String(characters[block.contentRange]))
            appendRule(selectorText: selectorText, declarations: declarations, into: &result)
            index = block.endIndex + 1
        }

        return result
    }

    static func resolveInlineAnimationBindings(
        from declarations: [String: String],
        inheritedBindings: [SVGAnimationBinding],
        target: SVGNodeTarget
    ) -> [SVGInlineAnimationBinding] {
        let hasAnimationNameInfo = declarations["animation"] != nil || declarations["animation-name"] != nil
        let namedInheritedBindings = inheritedBindings.filter { !$0.animationName.isEmpty }
        let anonymousInheritedBindings = inheritedBindings.filter(\.animationName.isEmpty)
        let hasAnimationOverrides = declarations.keys.contains { isAnimationOverrideProperty($0) }

        if hasAnimationNameInfo {
            let transformOrigin = declarations["transform-origin"].flatMap(parseTransformOrigin)
            let transformBox = declarations["transform-box"]?.trimmingCharacters(in: .whitespacesAndNewlines)

            return parseAnimationStyleBindings(
                declarations: declarations,
                transformOrigin: transformOrigin,
                transformBox: transformBox
            ).enumerated().compactMap { index, template in
                guard let animationName = template.animationName else {
                    return nil
                }

                let baseBinding = namedInheritedBindings.first { $0.animationName == animationName }
                    ?? indexedBinding(in: anonymousInheritedBindings, at: index)

                return SVGInlineAnimationBinding(
                    target: target,
                    animationName: animationName,
                    duration: template.duration ?? baseBinding?.duration ?? 0,
                    timingFunction: template.timingFunction ?? baseBinding?.timingFunction ?? defaultTimingFunction,
                    iterationCount: template.iterationCount ?? baseBinding?.iterationCount ?? .count(1),
                    direction: template.direction ?? baseBinding?.direction ?? .normal,
                    delay: template.delay ?? baseBinding?.delay ?? 0,
                    fillMode: template.fillMode ?? baseBinding?.fillMode ?? .none,
                    transformOrigin: template.transformOrigin ?? baseBinding?.transformOrigin,
                    transformBox: template.transformBox ?? baseBinding?.transformBox
                )
            }
        }

        guard hasAnimationOverrides, !namedInheritedBindings.isEmpty else {
            if !namedInheritedBindings.isEmpty {
                return namedInheritedBindings.map { binding in
                    SVGInlineAnimationBinding(
                        target: target,
                        animationName: binding.animationName,
                        duration: binding.duration,
                        timingFunction: binding.timingFunction,
                        iterationCount: binding.iterationCount,
                        direction: binding.direction,
                        delay: binding.delay,
                        fillMode: binding.fillMode,
                        transformOrigin: binding.transformOrigin,
                        transformBox: binding.transformBox
                    )
                }
            }
            return []
        }

        let transformOriginOverride = declarations["transform-origin"].flatMap(parseTransformOrigin)
        let transformBoxOverride = nonEmpty(declarations["transform-box"])
        let shorthandValues = commaSeparatedValues(for: declarations["animation"])
        let names = commaSeparatedValues(for: declarations["animation-name"])
        let durations = commaSeparatedValues(for: declarations["animation-duration"])
        let timingFunctions = commaSeparatedValues(for: declarations["animation-timing-function"])
        let iterationCounts = commaSeparatedValues(for: declarations["animation-iteration-count"])
        let directions = commaSeparatedValues(for: declarations["animation-direction"])
        let delays = commaSeparatedValues(for: declarations["animation-delay"])
        let fillModes = commaSeparatedValues(for: declarations["animation-fill-mode"])

        return namedInheritedBindings.enumerated().map { index, binding in
            let shorthand = indexedValue(in: shorthandValues, at: index)
            let parsedShorthand = shorthand.map(parseAnimationShorthand) ?? ParsedAnimationShorthand()

            let animationName = nonEmpty(indexedValue(in: names, at: index) ?? parsedShorthand.name) ?? binding.animationName
            let duration = parseTime(indexedValue(in: durations, at: index) ?? parsedShorthand.duration) ?? binding.duration
            let timingFunction = parseTimingFunction(indexedValue(in: timingFunctions, at: index) ?? parsedShorthand.timingFunction) ?? binding.timingFunction
            let iterationCount = parseIterationCount(indexedValue(in: iterationCounts, at: index) ?? parsedShorthand.iterationCount) ?? binding.iterationCount
            let direction = parseDirection(indexedValue(in: directions, at: index) ?? parsedShorthand.direction) ?? binding.direction
            let delay = parseTime(indexedValue(in: delays, at: index) ?? parsedShorthand.delay) ?? binding.delay
            let fillMode = parseFillMode(indexedValue(in: fillModes, at: index) ?? parsedShorthand.fillMode) ?? binding.fillMode

            return SVGInlineAnimationBinding(
                target: target,
                animationName: animationName,
                duration: duration,
                timingFunction: timingFunction,
                iterationCount: iterationCount,
                direction: direction,
                delay: delay,
                fillMode: fillMode,
                transformOrigin: transformOriginOverride ?? binding.transformOrigin,
                transformBox: transformBoxOverride ?? binding.transformBox
            )
        }
    }

    static func parseInlineDeclarations(_ source: String) -> [String: String] {
        parseDeclarations(source)
    }

    static func resolveInlineTransitionBindings(
        from declarations: [String: String],
        inheritedBindings: [SVGTransitionBinding],
        target: SVGNodeTarget
    ) -> [SVGInlineTransitionBinding] {
        let hasTransitionNameInfo = declarations["transition"] != nil || declarations["transition-property"] != nil
        let hasTransitionOverrides = declarations.keys.contains { isTransitionOverrideProperty($0) }

        if hasTransitionNameInfo {
            return parseTransitionStyleBindings(declarations: declarations).enumerated().map { index, template in
                let baseBinding = template.property.flatMap { property in
                    inheritedBindings.first { $0.property == property }
                } ?? indexedTransitionBinding(in: inheritedBindings, at: index)

                return SVGInlineTransitionBinding(
                    target: target,
                    property: template.property ?? baseBinding?.property ?? "all",
                    duration: template.duration ?? baseBinding?.duration ?? 0,
                    timingFunction: template.timingFunction ?? baseBinding?.timingFunction ?? defaultTimingFunction,
                    delay: template.delay ?? baseBinding?.delay ?? 0
                )
            }
        }

        guard hasTransitionOverrides, !inheritedBindings.isEmpty else {
            return []
        }

        let shorthandValues = commaSeparatedValues(for: declarations["transition"])
        let properties = commaSeparatedValues(for: declarations["transition-property"])
        let durations = commaSeparatedValues(for: declarations["transition-duration"])
        let timingFunctions = commaSeparatedValues(for: declarations["transition-timing-function"])
        let delays = commaSeparatedValues(for: declarations["transition-delay"])

        return inheritedBindings.enumerated().map { index, binding in
            let shorthand = indexedValue(in: shorthandValues, at: index)
            let parsedShorthand = shorthand.map(parseTransitionShorthand) ?? ParsedTransitionShorthand()

            let property = nonEmpty(indexedValue(in: properties, at: index) ?? parsedShorthand.property) ?? binding.property
            let duration = parseTime(indexedValue(in: durations, at: index) ?? parsedShorthand.duration) ?? binding.duration
            let timingFunction = parseTimingFunction(indexedValue(in: timingFunctions, at: index) ?? parsedShorthand.timingFunction) ?? binding.timingFunction
            let delay = parseTime(indexedValue(in: delays, at: index) ?? parsedShorthand.delay) ?? binding.delay

            return SVGInlineTransitionBinding(
                target: target,
                property: property,
                duration: duration,
                timingFunction: timingFunction,
                delay: delay
            )
        }
    }

    static func resolvedTransformOrigin(from rawValue: String) -> SVGTransformOrigin? {
        parseTransformOrigin(rawValue)
    }
}

private extension CSSParser {
    struct BalancedBlock: Sendable {
        var contentRange: Range<Int>
        var endIndex: Int
    }

    struct AnimationTemplate: Sendable {
        var animationName: String
        var duration: TimeInterval
        var timingFunction: TimingFunction
        var iterationCount: AnimationIterationCount
        var direction: AnimationDirection
        var delay: TimeInterval
        var fillMode: AnimationFillMode
        var transformOrigin: SVGTransformOrigin?
        var transformBox: String?
    }

    struct AnimationStyleTemplate: Sendable {
        var animationName: String?
        var duration: TimeInterval?
        var timingFunction: TimingFunction?
        var iterationCount: AnimationIterationCount?
        var direction: AnimationDirection?
        var delay: TimeInterval?
        var fillMode: AnimationFillMode?
        var transformOrigin: SVGTransformOrigin?
        var transformBox: String?
    }

    struct TransitionTemplate: Sendable {
        var property: String
        var duration: TimeInterval
        var timingFunction: TimingFunction
        var delay: TimeInterval
    }

    struct TransitionStyleTemplate: Sendable {
        var property: String?
        var duration: TimeInterval?
        var timingFunction: TimingFunction?
        var delay: TimeInterval?
    }

    struct ParsedAnimationShorthand: Sendable {
        var name: String?
        var duration: String?
        var timingFunction: String?
        var iterationCount: String?
        var direction: String?
        var delay: String?
        var fillMode: String?
    }

    struct ParsedTransitionShorthand: Sendable {
        var property: String?
        var duration: String?
        var timingFunction: String?
        var delay: String?
    }

    static func stripComments(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#,
            with: "",
            options: .regularExpression
        )
    }

    static func appendRule(
        selectorText: String,
        declarations: [String: String],
        into result: inout CSSResult
    ) {
        let selectors = parseSelectors(selectorText)
        guard !selectors.isEmpty else {
            return
        }

        let transformOrigin = declarations["transform-origin"].flatMap(parseTransformOrigin)
        let transformBox = declarations["transform-box"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let staticProperties = staticRuleProperties(from: declarations)

        if !staticProperties.isEmpty {
            for selector in selectors {
                result.staticStyleBindings.append(
                    SVGStaticStyleBinding(
                        selector: selector,
                        properties: staticProperties
                    )
                )
            }
        }

        let animationStyleTemplates = parseAnimationStyleBindings(
            declarations: declarations,
            transformOrigin: transformOrigin,
            transformBox: transformBox
        )
        for selector in selectors {
            for template in animationStyleTemplates {
                result.animationStyleBindings.append(
                    SVGAnimationStyleBinding(
                        selector: selector,
                        animationName: template.animationName,
                        duration: template.duration,
                        timingFunction: template.timingFunction,
                        iterationCount: template.iterationCount,
                        direction: template.direction,
                        delay: template.delay,
                        fillMode: template.fillMode,
                        transformOrigin: template.transformOrigin,
                        transformBox: template.transformBox
                    )
                )
            }
        }

        let animationTemplates = parseAnimationBindings(
            declarations: declarations,
            transformOrigin: transformOrigin,
            transformBox: transformBox
        )
        for selector in selectors {
            for template in animationTemplates {
                result.animationBindings.append(
                    SVGAnimationBinding(
                        selector: selector,
                        animationName: template.animationName,
                        duration: template.duration,
                        timingFunction: template.timingFunction,
                        iterationCount: template.iterationCount,
                        direction: template.direction,
                        delay: template.delay,
                        fillMode: template.fillMode,
                        transformOrigin: template.transformOrigin,
                        transformBox: template.transformBox
                    )
                )
            }
        }

        let transitionTemplates = parseTransitionBindings(declarations: declarations)
        for selector in selectors {
            for template in transitionTemplates {
                result.transitions.append(
                    SVGTransitionBinding(
                        selector: selector,
                        property: template.property,
                        duration: template.duration,
                        timingFunction: template.timingFunction,
                        delay: template.delay
                    )
                )
            }
        }
    }

    static func parseSelectors(_ selectorText: String) -> [CSSSelector] {
        splitAware(selectorText, delimiter: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(parseSelector)
    }

    static func parseSelector(_ rawSelector: String) -> CSSSelector? {
        guard !rawSelector.isEmpty else {
            return nil
        }

        if rawSelector.range(of: #"^\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            return .className(String(rawSelector.dropFirst()))
        }
        if rawSelector.range(of: #"^#[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            return .id(String(rawSelector.dropFirst()))
        }

        return nil
    }

    static func parseAnimationBindings(
        declarations: [String: String],
        transformOrigin: SVGTransformOrigin?,
        transformBox: String?
    ) -> [AnimationTemplate] {
        let shorthandValues = commaSeparatedValues(for: declarations["animation"])
        let names = commaSeparatedValues(for: declarations["animation-name"])
        let durations = commaSeparatedValues(for: declarations["animation-duration"])
        let timingFunctions = commaSeparatedValues(for: declarations["animation-timing-function"])
        let iterationCounts = commaSeparatedValues(for: declarations["animation-iteration-count"])
        let directions = commaSeparatedValues(for: declarations["animation-direction"])
        let delays = commaSeparatedValues(for: declarations["animation-delay"])
        let fillModes = commaSeparatedValues(for: declarations["animation-fill-mode"])

        let bindingCount = max(
            shorthandValues.count,
            names.count,
            durations.count,
            timingFunctions.count,
            iterationCounts.count,
            directions.count,
            delays.count,
            fillModes.count
        )

        guard bindingCount > 0 else {
            return []
        }

        var bindings: [AnimationTemplate] = []
        bindings.reserveCapacity(bindingCount)

        for index in 0..<bindingCount {
            let shorthand = indexedValue(in: shorthandValues, at: index)
            let parsedShorthand = shorthand.map(parseAnimationShorthand) ?? ParsedAnimationShorthand()

            guard let animationName = nonEmpty(indexedValue(in: names, at: index) ?? parsedShorthand.name) else {
                continue
            }

            let duration = parseTime(indexedValue(in: durations, at: index) ?? parsedShorthand.duration) ?? 0
            let timingFunction = parseTimingFunction(indexedValue(in: timingFunctions, at: index) ?? parsedShorthand.timingFunction) ?? defaultTimingFunction
            let iterationCount = parseIterationCount(indexedValue(in: iterationCounts, at: index) ?? parsedShorthand.iterationCount) ?? .count(1)
            let direction = parseDirection(indexedValue(in: directions, at: index) ?? parsedShorthand.direction) ?? .normal
            let delay = parseTime(indexedValue(in: delays, at: index) ?? parsedShorthand.delay) ?? 0
            let fillMode = parseFillMode(indexedValue(in: fillModes, at: index) ?? parsedShorthand.fillMode) ?? .none

            bindings.append(
                AnimationTemplate(
                    animationName: animationName,
                    duration: duration,
                    timingFunction: timingFunction,
                    iterationCount: iterationCount,
                    direction: direction,
                    delay: delay,
                    fillMode: fillMode,
                    transformOrigin: transformOrigin,
                    transformBox: nonEmpty(transformBox)
                )
            )
        }

        return bindings
    }

    static func parseAnimationStyleBindings(
        declarations: [String: String],
        transformOrigin: SVGTransformOrigin?,
        transformBox: String?
    ) -> [AnimationStyleTemplate] {
        let shorthandValues = commaSeparatedValues(for: declarations["animation"])
        let names = commaSeparatedValues(for: declarations["animation-name"])
        let durations = commaSeparatedValues(for: declarations["animation-duration"])
        let timingFunctions = commaSeparatedValues(for: declarations["animation-timing-function"])
        let iterationCounts = commaSeparatedValues(for: declarations["animation-iteration-count"])
        let directions = commaSeparatedValues(for: declarations["animation-direction"])
        let delays = commaSeparatedValues(for: declarations["animation-delay"])
        let fillModes = commaSeparatedValues(for: declarations["animation-fill-mode"])
        let hasTransformContext = transformOrigin != nil || nonEmpty(transformBox) != nil

        let bindingCount = max(
            shorthandValues.count,
            names.count,
            durations.count,
            timingFunctions.count,
            iterationCounts.count,
            directions.count,
            delays.count,
            fillModes.count,
            hasTransformContext ? 1 : 0
        )

        guard bindingCount > 0 else {
            return []
        }

        var bindings: [AnimationStyleTemplate] = []
        bindings.reserveCapacity(bindingCount)

        for index in 0..<bindingCount {
            let shorthand = indexedValue(in: shorthandValues, at: index)
            let parsedShorthand = shorthand.map(parseAnimationShorthand) ?? ParsedAnimationShorthand()

            let binding = AnimationStyleTemplate(
                animationName: nonEmpty(indexedValue(in: names, at: index) ?? parsedShorthand.name),
                duration: parseTime(indexedValue(in: durations, at: index) ?? parsedShorthand.duration),
                timingFunction: parseTimingFunction(indexedValue(in: timingFunctions, at: index) ?? parsedShorthand.timingFunction),
                iterationCount: parseIterationCount(indexedValue(in: iterationCounts, at: index) ?? parsedShorthand.iterationCount),
                direction: parseDirection(indexedValue(in: directions, at: index) ?? parsedShorthand.direction),
                delay: parseTime(indexedValue(in: delays, at: index) ?? parsedShorthand.delay),
                fillMode: parseFillMode(indexedValue(in: fillModes, at: index) ?? parsedShorthand.fillMode),
                transformOrigin: transformOrigin,
                transformBox: nonEmpty(transformBox)
            )

            if binding.animationName != nil ||
                binding.duration != nil ||
                binding.timingFunction != nil ||
                binding.iterationCount != nil ||
                binding.direction != nil ||
                binding.delay != nil ||
                binding.fillMode != nil ||
                binding.transformOrigin != nil ||
                binding.transformBox != nil {
                bindings.append(binding)
            }
        }

        return bindings
    }

    static func parseAnimationShorthand(_ value: String) -> ParsedAnimationShorthand {
        var result = ParsedAnimationShorthand()

        for token in splitWhitespaceAware(value) {
            if isTimeToken(token) {
                if result.duration == nil {
                    result.duration = token
                } else if result.delay == nil {
                    result.delay = token
                }
                continue
            }

            // CSS animation shorthand consumes ambiguous keywords as other subproperties
            // before they can be treated as a keyframes name.
            if isTimingFunctionToken(token), result.timingFunction == nil {
                result.timingFunction = token
                continue
            }

            if isIterationCountToken(token), result.iterationCount == nil {
                result.iterationCount = token
                continue
            }

            if isDirectionToken(token), result.direction == nil {
                result.direction = token
                continue
            }

            if isFillModeToken(token), result.fillMode == nil {
                result.fillMode = token
                continue
            }

            if isPlayStateToken(token) {
                continue
            }

            if result.name == nil {
                result.name = token
            }
        }

        return result
    }

    static func parseTransitionBindings(declarations: [String: String]) -> [TransitionTemplate] {
        let shorthandValues = commaSeparatedValues(for: declarations["transition"])
        let properties = commaSeparatedValues(for: declarations["transition-property"])
        let durations = commaSeparatedValues(for: declarations["transition-duration"])
        let timingFunctions = commaSeparatedValues(for: declarations["transition-timing-function"])
        let delays = commaSeparatedValues(for: declarations["transition-delay"])

        let bindingCount = max(
            shorthandValues.count,
            properties.count,
            durations.count,
            timingFunctions.count,
            delays.count
        )

        guard bindingCount > 0 else {
            return []
        }

        var bindings: [TransitionTemplate] = []
        bindings.reserveCapacity(bindingCount)

        for index in 0..<bindingCount {
            let shorthand = indexedValue(in: shorthandValues, at: index)
            let parsedShorthand = shorthand.map(parseTransitionShorthand) ?? ParsedTransitionShorthand()

            guard let property = nonEmpty(indexedValue(in: properties, at: index) ?? parsedShorthand.property) else {
                continue
            }

            let duration = parseTime(indexedValue(in: durations, at: index) ?? parsedShorthand.duration) ?? 0
            let timingFunction = parseTimingFunction(indexedValue(in: timingFunctions, at: index) ?? parsedShorthand.timingFunction) ?? defaultTimingFunction
            let delay = parseTime(indexedValue(in: delays, at: index) ?? parsedShorthand.delay) ?? 0

            bindings.append(
                TransitionTemplate(
                    property: property,
                    duration: duration,
                    timingFunction: timingFunction,
                    delay: delay
                )
            )
        }

        return bindings
    }

    static func parseTransitionStyleBindings(declarations: [String: String]) -> [TransitionStyleTemplate] {
        let shorthandValues = commaSeparatedValues(for: declarations["transition"])
        let properties = commaSeparatedValues(for: declarations["transition-property"])
        let durations = commaSeparatedValues(for: declarations["transition-duration"])
        let timingFunctions = commaSeparatedValues(for: declarations["transition-timing-function"])
        let delays = commaSeparatedValues(for: declarations["transition-delay"])

        let bindingCount = max(
            shorthandValues.count,
            properties.count,
            durations.count,
            timingFunctions.count,
            delays.count
        )

        guard bindingCount > 0 else {
            return []
        }

        var bindings: [TransitionStyleTemplate] = []
        bindings.reserveCapacity(bindingCount)

        for index in 0..<bindingCount {
            let shorthand = indexedValue(in: shorthandValues, at: index)
            let parsedShorthand = shorthand.map(parseTransitionShorthand) ?? ParsedTransitionShorthand()

            let binding = TransitionStyleTemplate(
                property: nonEmpty(indexedValue(in: properties, at: index) ?? parsedShorthand.property),
                duration: parseTime(indexedValue(in: durations, at: index) ?? parsedShorthand.duration),
                timingFunction: parseTimingFunction(indexedValue(in: timingFunctions, at: index) ?? parsedShorthand.timingFunction),
                delay: parseTime(indexedValue(in: delays, at: index) ?? parsedShorthand.delay)
            )

            if binding.property != nil ||
                binding.duration != nil ||
                binding.timingFunction != nil ||
                binding.delay != nil {
                bindings.append(binding)
            }
        }

        return bindings
    }

    static func parseTransitionShorthand(_ value: String) -> ParsedTransitionShorthand {
        var result = ParsedTransitionShorthand()

        for token in splitWhitespaceAware(value) {
            if isTimeToken(token) {
                if result.duration == nil {
                    result.duration = token
                } else if result.delay == nil {
                    result.delay = token
                }
                continue
            }

            if isTimingFunctionToken(token), result.timingFunction == nil {
                result.timingFunction = token
                continue
            }

            if result.property == nil {
                result.property = token
            }
        }

        return result
    }

    static func parseKeyframes(name: String, body: String) -> SVGAnimation {
        let characters = Array(body)
        var keyframes: [SVGKeyframe] = []
        var index = 0

        while true {
            index = skipIgnorable(characters, from: index)
            guard index < characters.count else {
                break
            }

            guard let braceIndex = findNextTopLevel(in: characters, target: "{", start: index),
                  let block = readBalancedBlock(in: characters, openBraceIndex: braceIndex)
            else {
                break
            }

            let offsetText = trimmedString(from: characters, start: index, end: braceIndex)
            let offsets = splitAware(offsetText, delimiter: ",").compactMap(parseKeyframeOffset)
            let properties = parseDeclarations(String(characters[block.contentRange]))

            if !offsets.isEmpty {
                keyframes.append(
                    SVGKeyframe(
                        offsets: offsets.map { CGFloat($0) },
                        properties: properties
                    )
                )
            }

            index = block.endIndex + 1
        }

        return SVGAnimation(name: name, keyframes: keyframes)
    }

    static func parseKeyframeOffset(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "from" {
            return 0
        }
        if trimmed == "to" {
            return 1
        }
        guard trimmed.hasSuffix("%") else {
            return nil
        }

        let number = String(trimmed.dropLast())
        guard let value = Double(number) else {
            return nil
        }

        return value / 100
    }

    static func parseDeclarations(_ source: String) -> [String: String] {
        var declarations: [String: String] = [:]

        for segment in splitAware(source, delimiter: ";") {
            let declaration = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !declaration.isEmpty else {
                continue
            }

            let characters = Array(declaration)
            guard let colonIndex = findNextTopLevel(in: characters, target: ":", start: 0) else {
                continue
            }

            let property = trimmedString(from: characters, start: 0, end: colonIndex).lowercased()
            let value = trimmedString(from: characters, start: colonIndex + 1, end: characters.count)

            if !property.isEmpty, !value.isEmpty {
                declarations[property] = value
            }
        }

        return declarations
    }

    static func staticRuleProperties(from declarations: [String: String]) -> [String: String] {
        var properties: [String: String] = [:]

        for (property, value) in declarations {
            guard shouldPreserveStaticProperty(property) else {
                continue
            }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                properties[property] = trimmed
            }
        }

        return properties
    }

    static func shouldPreserveStaticProperty(_ property: String) -> Bool {
        if property.hasPrefix("animation-") || property == "animation" {
            return false
        }

        if property.hasPrefix("transition-") || property == "transition" {
            return false
        }

        return true
    }

    static func isAnimationOverrideProperty(_ property: String) -> Bool {
        if property == "transform-origin" || property == "transform-box" {
            return true
        }

        return property == "animation" || property.hasPrefix("animation-")
    }

    static func isTransitionOverrideProperty(_ property: String) -> Bool {
        property == "transition" || property.hasPrefix("transition-")
    }

    static func parseTimingFunction(_ rawValue: String?) -> TimingFunction? {
        guard let trimmed = nonEmpty(rawValue)?.lowercased() else {
            return nil
        }

        switch trimmed {
        case "ease-in-out":
            return .easeInOut
        case "linear":
            return .linear
        case "ease-out":
            return .easeOut
        case "ease-in":
            return .easeIn
        case "step-end":
            return .stepEnd
        case "ease":
            return .cubicBezier(0.25, 0.1, 0.25, 1)
        default:
            guard trimmed.hasPrefix("cubic-bezier("), trimmed.hasSuffix(")") else {
                return nil
            }

            let arguments = String(trimmed.dropFirst("cubic-bezier(".count).dropLast())
            let values = splitAware(arguments, delimiter: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(Double.init)

            guard values.count == 4 else {
                return nil
            }

            return .cubicBezier(
                CGFloat(values[0]),
                CGFloat(values[1]),
                CGFloat(values[2]),
                CGFloat(values[3])
            )
        }
    }

    static func parseIterationCount(_ rawValue: String?) -> AnimationIterationCount? {
        guard let trimmed = nonEmpty(rawValue)?.lowercased() else {
            return nil
        }

        if trimmed == "infinite" {
            return .infinite
        }

        if let intValue = Int(trimmed) {
            return .count(Double(intValue))
        }

        if let doubleValue = Double(trimmed), doubleValue.isFinite {
            return .count(doubleValue)
        }

        return nil
    }

    static func parseDirection(_ rawValue: String?) -> AnimationDirection? {
        guard let trimmed = nonEmpty(rawValue)?.lowercased() else {
            return nil
        }

        switch trimmed {
        case "normal":
            return .normal
        case "reverse":
            return .reverse
        case "alternate":
            return .alternate
        case "alternate-reverse":
            return .alternateReverse
        default:
            return nil
        }
    }

    static func parseFillMode(_ rawValue: String?) -> AnimationFillMode? {
        guard let trimmed = nonEmpty(rawValue)?.lowercased() else {
            return nil
        }

        switch trimmed {
        case "none":
            return AnimationFillMode.none
        case "forwards":
            return .forwards
        case "backwards":
            return .backwards
        case "both":
            return .both
        default:
            return nil
        }
    }

    static func parseTransformOrigin(_ rawValue: String) -> SVGTransformOrigin? {
        let tokens = splitWhitespaceAware(rawValue)
        guard !tokens.isEmpty else {
            return nil
        }

        if tokens.count == 1 {
            let token = tokens[0].lowercased()
            if isVerticalOriginKeyword(token) {
                guard let y = originComponent(from: token, axis: .vertical) else {
                    return nil
                }
                return SVGTransformOrigin(x: .percent(50), y: y)
            }

            guard let x = originComponent(from: token, axis: .horizontal) ?? originComponent(from: token, axis: .vertical) else {
                return nil
            }
            let y = token == "center" ? x : SVGTransformOriginComponent.percent(50)
            return SVGTransformOrigin(x: x, y: y)
        }

        let first = tokens[0].lowercased()
        let second = tokens[1].lowercased()

        if isVerticalOriginKeyword(first) && !isVerticalOriginKeyword(second) {
            guard let x = originComponent(from: second, axis: .horizontal) ?? originComponent(from: second, axis: .vertical),
                  let y = originComponent(from: first, axis: .vertical)
            else {
                return nil
            }
            return SVGTransformOrigin(x: x, y: y)
        }

        guard let x = originComponent(from: first, axis: .horizontal) ?? originComponent(from: first, axis: .vertical),
              let y = originComponent(from: second, axis: .vertical) ?? originComponent(from: second, axis: .horizontal)
        else {
            return nil
        }

        return SVGTransformOrigin(x: x, y: y)
    }

    static func parseTime(_ rawValue: String?) -> TimeInterval? {
        guard let trimmed = nonEmpty(rawValue)?.lowercased() else {
            return nil
        }

        if trimmed.hasSuffix("ms") {
            let number = String(trimmed.dropLast(2))
            guard let value = Double(number) else {
                return nil
            }
            return value / 1_000
        }

        if trimmed.hasSuffix("s") {
            let number = String(trimmed.dropLast())
            return Double(number)
        }

        return nil
    }

    static func commaSeparatedValues(for rawValue: String?) -> [String] {
        guard let rawValue = rawValue else {
            return []
        }

        return splitAware(rawValue, delimiter: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func indexedValue(in values: [String], at index: Int) -> String? {
        guard !values.isEmpty else {
            return nil
        }
        if index < values.count {
            return values[index]
        }
        if values.count == 1 {
            return values[0]
        }
        return nil
    }

    static func indexedBinding(in bindings: [SVGAnimationBinding], at index: Int) -> SVGAnimationBinding? {
        guard !bindings.isEmpty else {
            return nil
        }
        if index < bindings.count {
            return bindings[index]
        }
        if bindings.count == 1 {
            return bindings[0]
        }
        return nil
    }

    static func indexedTransitionBinding(in bindings: [SVGTransitionBinding], at index: Int) -> SVGTransitionBinding? {
        guard !bindings.isEmpty else {
            return nil
        }
        if index < bindings.count {
            return bindings[index]
        }
        if bindings.count == 1 {
            return bindings[0]
        }
        return nil
    }

    static func splitWhitespaceAware(_ source: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depthParen = 0
        var depthBracket = 0
        var quote: Character?

        for character in source {
            if let currentQuote = quote {
                current.append(character)
                if character == currentQuote {
                    quote = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                continue
            }

            if character == "(" {
                depthParen += 1
                current.append(character)
                continue
            }

            if character == ")" {
                depthParen = max(0, depthParen - 1)
                current.append(character)
                continue
            }

            if character == "[" {
                depthBracket += 1
                current.append(character)
                continue
            }

            if character == "]" {
                depthBracket = max(0, depthBracket - 1)
                current.append(character)
                continue
            }

            if character.isWhitespace && depthParen == 0 && depthBracket == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    tokens.append(trimmed)
                }
                current.removeAll(keepingCapacity: true)
                continue
            }

            current.append(character)
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tokens.append(trimmed)
        }

        return tokens
    }

    static func splitAware(_ source: String, delimiter: Character) -> [String] {
        let characters = Array(source)
        var items: [String] = []
        var startIndex = 0
        var depthParen = 0
        var depthBracket = 0
        var quote: Character?

        for index in 0..<characters.count {
            let character = characters[index]

            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character == "(" {
                depthParen += 1
                continue
            }

            if character == ")" {
                depthParen = max(0, depthParen - 1)
                continue
            }

            if character == "[" {
                depthBracket += 1
                continue
            }

            if character == "]" {
                depthBracket = max(0, depthBracket - 1)
                continue
            }

            if character == delimiter && depthParen == 0 && depthBracket == 0 {
                items.append(String(characters[startIndex..<index]))
                startIndex = index + 1
            }
        }

        items.append(String(characters[startIndex..<characters.count]))
        return items
    }

    static func skipIgnorable(_ characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace || character == ";" {
                index += 1
            } else {
                break
            }
        }
        return index
    }

    static func findNextTopLevel(in characters: [Character], target: Character, start: Int) -> Int? {
        var depthParen = 0
        var depthBracket = 0
        var quote: Character?

        for index in start..<characters.count {
            let character = characters[index]

            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character == "(" {
                depthParen += 1
                continue
            }

            if character == ")" {
                depthParen = max(0, depthParen - 1)
                continue
            }

            if character == "[" {
                depthBracket += 1
                continue
            }

            if character == "]" {
                depthBracket = max(0, depthBracket - 1)
                continue
            }

            if depthParen == 0 && depthBracket == 0 && character == target {
                return index
            }
        }

        return nil
    }

    static func readBalancedBlock(in characters: [Character], openBraceIndex: Int) -> BalancedBlock? {
        var depth = 0
        var quote: Character?

        for index in openBraceIndex..<characters.count {
            let character = characters[index]

            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character == "{" {
                depth += 1
                continue
            }

            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return BalancedBlock(
                        contentRange: (openBraceIndex + 1)..<index,
                        endIndex: index
                    )
                }
            }
        }

        return nil
    }

    static func trimmedString(from characters: [Character], start: Int, end: Int) -> String {
        guard start < end else {
            return ""
        }
        return String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func isTimeToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return parseTime(trimmed) != nil
    }

    static func isTimingFunctionToken(_ token: String) -> Bool {
        parseTimingFunction(token) != nil
    }

    static func isIterationCountToken(_ token: String) -> Bool {
        parseIterationCount(token) != nil
    }

    static func isFillModeToken(_ token: String) -> Bool {
        parseFillMode(token) != nil
    }

    static func isDirectionToken(_ token: String) -> Bool {
        parseDirection(token) != nil
    }

    static func isPlayStateToken(_ token: String) -> Bool {
        switch token.lowercased() {
        case "running", "paused":
            return true
        default:
            return false
        }
    }

    static func isVerticalOriginKeyword(_ token: String) -> Bool {
        switch token {
        case "top", "bottom":
            return true
        default:
            return false
        }
    }

    enum OriginAxis {
        case horizontal
        case vertical
    }

    static func originComponent(from token: String, axis: OriginAxis) -> SVGTransformOriginComponent? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch trimmed {
        case "left" where axis == .horizontal:
            return .percent(0)
        case "right" where axis == .horizontal:
            return .percent(100)
        case "top" where axis == .vertical:
            return .percent(0)
        case "bottom" where axis == .vertical:
            return .percent(100)
        case "center":
            return .percent(50)
        default:
            break
        }

        if trimmed.hasSuffix("px") {
            return Double(String(trimmed[..<trimmed.index(trimmed.endIndex, offsetBy: -2)])).map {
                SVGTransformOriginComponent.px(CGFloat($0))
            }
        }

        if trimmed.hasSuffix("%") {
            return Double(String(trimmed[..<trimmed.index(before: trimmed.endIndex)])).map {
                SVGTransformOriginComponent.percent(CGFloat($0))
            }
        }

        return Double(trimmed).map {
            SVGTransformOriginComponent.px(CGFloat($0))
        }
    }
}
