import Foundation
import SwiftUI

enum PermissionDecision {
    case allow
    case deny
    case suggestion(PermissionSuggestion)

    var behavior: PermissionBehavior {
        switch self {
        case .allow:
            return .allow
        case .deny:
            return .deny
        case .suggestion(let suggestion):
            return suggestion.behavior
        }
    }

    /// 选中 suggestion 时需要把原始 payload 透传回 Claude Code 作为 updatedPermissions。
    var suggestionPayloads: [Data] {
        switch self {
        case .suggestion(let suggestion):
            return suggestion.resolvedPayloads
        default:
            return []
        }
    }
}

struct PermissionSuggestion: Identifiable, Equatable {
    enum Kind: String {
        case addRules
        case setMode
    }

    let id = UUID()
    let kind: Kind
    let behavior: PermissionBehavior
    let label: String
    /// 按照 Claude Code 要求格式化的 suggestion 数据，序列化为 JSON Data。
    let resolvedPayloads: [Data]

    static func == (lhs: PermissionSuggestion, rhs: PermissionSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

struct PermissionBubbleContent {
    let sessionId: String
    let toolName: String
    let toolInput: String
    let suggestions: [PermissionSuggestion]

    static func decode(from body: Data) -> PermissionBubbleContent? {
        guard
            let payload = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
            let rawToolName = payload["tool_name"] as? String
        else {
            return nil
        }

        let sessionId = normalizedString(payload["session_id"] as? String) ?? "default"
        let toolName = normalizedString(rawToolName) ?? "Unknown"
        let toolInput = previewJSONString(payload["tool_input"])
        let suggestions = decodeSuggestions(from: payload["permission_suggestions"])

        return PermissionBubbleContent(
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            suggestions: suggestions
        )
    }

    var estimatedHeight: CGFloat {
        // Suggestions are in HStack, so they only add one row of height if present.
        // Base: ~160 for tool pill + input preview + button row + padding.
        // Add one extra row (~37px) only if suggestions cause wrapping.
        let baseHeight: CGFloat = 170
        let suggestionRowHeight: CGFloat = suggestions.isEmpty ? 0 : 37
        return baseHeight + suggestionRowHeight
    }

    private static func decodeSuggestions(from rawValue: Any?) -> [PermissionSuggestion] {
        guard let rawSuggestions = rawValue as? [[String: Any]] else {
            return []
        }

        var seenPayloads = Set<Data>()
        var suggestions: [PermissionSuggestion] = []

        for rawSuggestion in rawSuggestions {
            guard
                let type = rawSuggestion["type"] as? String,
                let kind = PermissionSuggestion.Kind(rawValue: type),
                let rawBehavior = rawSuggestion["behavior"] as? String,
                let behavior = PermissionBehavior(rawValue: rawBehavior),
                behavior == .allow
            else {
                continue
            }

            guard let resolvedPayload = resolveSuggestionEntry(kind: kind, behavior: behavior, raw: rawSuggestion) else {
                continue
            }

            guard let payloadData = try? JSONSerialization.data(withJSONObject: resolvedPayload) else {
                continue
            }
            guard seenPayloads.insert(payloadData).inserted else {
                continue
            }

            suggestions.append(
                PermissionSuggestion(
                    kind: kind,
                    behavior: behavior,
                    label: suggestionLabel(for: kind, behavior: behavior, payload: resolvedPayload),
                    resolvedPayloads: [payloadData]
                )
            )
        }

        return suggestions
    }

    /// 按照 Claude Code 要求的 updatedPermissions 格式规范化 suggestion 原始数据。
    private static func resolveSuggestionEntry(
        kind: PermissionSuggestion.Kind,
        behavior: PermissionBehavior,
        raw: [String: Any]
    ) -> [String: Any]? {
        var resolved: [String: Any]

        switch kind {
        case .addRules:
            let rules: [[String: Any]]
            if let rawRules = raw["rules"] as? [[String: Any]] {
                rules = rawRules
            } else if let toolName = raw["toolName"] as? String {
                rules = [["toolName": toolName, "ruleContent": raw["ruleContent"] ?? ""]]
            } else {
                rules = []
            }

            resolved = [
                "type": "addRules",
                "destination": (raw["destination"] as? String) ?? "localSettings",
                "behavior": behavior.rawValue,
                "rules": rules,
            ]

        case .setMode:
            resolved = [
                "type": "setMode",
                "destination": (raw["destination"] as? String) ?? "localSettings",
            ]
            if let mode = raw["mode"] {
                resolved["mode"] = mode
            }
        }

        return resolved
    }

    private static func suggestionLabel(
        for kind: PermissionSuggestion.Kind,
        behavior: PermissionBehavior,
        payload: [String: Any]
    ) -> String {
        switch kind {
        case .addRules:
            let rules = (payload["rules"] as? [[String: Any]]) ?? []
            let baseLabel = addRulesLabel(for: rules)
            return decorateLabel(baseLabel, destination: payload["destination"] as? String)
        case .setMode:
            if let mode = normalizedString(payload["mode"] as? String) {
                return decorateLabel("Mode: \(mode)", destination: payload["destination"] as? String)
            }
            return decorateLabel("Allow in Mode", destination: payload["destination"] as? String)
        }
    }

    private static func addRulesLabel(for rules: [[String: Any]]) -> String {
        guard let firstRule = rules.first else {
            return "Always Allow"
        }

        let toolName = normalizedString(firstRule["toolName"] as? String)
        let ruleContent = normalizedString(firstRule["ruleContent"] as? String)

        let baseLabel: String
        if let ruleContent {
            if ruleContent.contains("**") {
                let dir = ruleContent
                    .components(separatedBy: "**")
                    .first?
                    .replacingOccurrences(of: "\\", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .split(separator: "/")
                    .last
                    .map(String.init)
                if let toolName, let dir, !dir.isEmpty {
                    baseLabel = "Allow \(toolName) in \(dir)/"
                } else if let dir, !dir.isEmpty {
                    baseLabel = "Allow in \(dir)/"
                } else {
                    baseLabel = "Always Allow"
                }
            } else {
                let shortRule = ruleContent.count > 30 ? String(ruleContent.prefix(29)) + "…" : ruleContent
                if let toolName {
                    baseLabel = "Allow \(toolName) `\(shortRule)`"
                } else {
                    baseLabel = "Always Allow `\(shortRule)`"
                }
            }
        } else if let toolName {
            baseLabel = "Allow \(toolName)"
        } else {
            baseLabel = "Always Allow"
        }

        if rules.count > 1 {
            return "\(baseLabel) +\(rules.count - 1)"
        }

        return baseLabel
    }

    private static func decorateLabel(_ label: String, destination: String?) -> String {
        switch normalizedString(destination) {
        case "projectSettings":
            return "\(label) (Project)"
        case "localSettings", nil:
            return label
        case let value?:
            return "\(label) (\(value))"
        }
    }

    private static func previewJSONString(_ value: Any?) -> String {
        guard let value else {
            return "{}"
        }

        if let text = value as? String {
            return normalizedString(text) ?? "\"\""
        }

        guard JSONSerialization.isValidJSONObject(value) else {
            return String(describing: value)
        }

        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else {
            return String(describing: value)
        }

        return String(decoding: data, as: UTF8.self)
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct BubbleView: View {
    let toolName: String
    let toolInput: String
    let suggestions: [PermissionSuggestion]
    let onDecide: (PermissionDecision) -> Void
    var onDismiss: (() -> Void)?
    var onContentHeightChanged: (() -> Void)?

    @State private var isInputExpanded = false

    /// 展开时最大高度限制，防止长内容撑出屏幕。
    private static let expandedMaxHeight: CGFloat = 280

    @ViewBuilder
    private var inputSection: some View {
        let text = Text(toolInput)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.leading)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

        if isInputExpanded {
            ScrollView(.vertical, showsIndicators: true) {
                text
            }
            .frame(maxHeight: Self.expandedMaxHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                isInputExpanded = false
                DispatchQueue.main.async { onContentHeightChanged?() }
            }
        } else {
            text
                .lineLimit(3)
                .contentShape(Rectangle())
                .onTapGesture {
                    isInputExpanded = true
                    DispatchQueue.main.async { onContentHeightChanged?() }
                }
        }
    }

    @ViewBuilder
    private var buttonGroup: some View {
        let buttons = Group {
            Button("Allow") { onDecide(.allow) }

            Button("Deny") { onDecide(.deny) }

            ForEach(suggestions) { suggestion in
                Button(suggestion.label) {
                    onDecide(.suggestion(suggestion))
                }
                .font(.caption)
            }
        }

        if #available(macOS 13.0, *) {
            FlowLayout(spacing: 8) { buttons }
        } else {
            HStack(spacing: 8) { buttons }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(toolName)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.blue.opacity(0.2)))
                Spacer()
                Button(action: { onDismiss?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }

            inputSection

            buttonGroup
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
    }
}

@available(macOS 13.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return LayoutResult(
            size: CGSize(width: maxX, height: currentY + rowHeight),
            positions: positions
        )
    }
}
