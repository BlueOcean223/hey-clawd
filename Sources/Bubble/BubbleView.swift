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
}

struct PermissionBubbleContent {
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

        let toolName = normalizedString(rawToolName) ?? "Unknown"
        let toolInput = previewJSONString(payload["tool_input"])
        let suggestions = decodeSuggestions(from: payload["permission_suggestions"])

        return PermissionBubbleContent(
            toolName: toolName,
            toolInput: toolInput,
            suggestions: suggestions
        )
    }

    var estimatedHeight: CGFloat {
        200 + CGFloat(suggestions.count * 37)
    }

    private static func decodeSuggestions(from rawValue: Any?) -> [PermissionSuggestion] {
        guard let rawSuggestions = rawValue as? [[String: Any]] else {
            return []
        }

        var suggestions: [PermissionSuggestion] = []
        var mergedAddRules = Set<String>()

        for rawSuggestion in rawSuggestions {
            guard
                let type = rawSuggestion["type"] as? String,
                let kind = PermissionSuggestion.Kind(rawValue: type),
                let rawBehavior = rawSuggestion["behavior"] as? String,
                let behavior = PermissionBehavior(rawValue: rawBehavior)
            else {
                continue
            }

            // Claude 可能返回多条 addRules 建议；4.1 只先合成一个按钮，避免 UI 被规则列表撑爆。
            if kind == .addRules {
                let mergeKey = "\(kind.rawValue):\(behavior.rawValue)"
                guard !mergedAddRules.contains(mergeKey) else {
                    continue
                }
                mergedAddRules.insert(mergeKey)
            }

            suggestions.append(
                PermissionSuggestion(
                    kind: kind,
                    behavior: behavior,
                    label: suggestionLabel(for: kind, behavior: behavior, payload: rawSuggestion)
                )
            )
        }

        return suggestions
    }

    private static func suggestionLabel(
        for kind: PermissionSuggestion.Kind,
        behavior: PermissionBehavior,
        payload: [String: Any]
    ) -> String {
        switch kind {
        case .addRules:
            return behavior == .allow ? "Always Allow" : "Always Deny"
        case .setMode:
            if let mode = normalizedString(payload["mode"] as? String) {
                return "Mode: \(mode)"
            }
            return behavior == .allow ? "Allow in Mode" : "Deny in Mode"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(toolName)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.blue.opacity(0.2)))
                Spacer()
            }

            Text(toolInput)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Allow") { onDecide(.allow) }
                    .keyboardShortcut(.defaultAction)

                Button("Deny") { onDecide(.deny) }

                ForEach(suggestions) { suggestion in
                    Button(suggestion.label) {
                        onDecide(.suggestion(suggestion))
                    }
                    .font(.caption)
                }
            }
        }
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
