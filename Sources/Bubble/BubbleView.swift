import Foundation
import SwiftUI

/// 用户在权限气泡上的决策结果。`suggestion` 用于"本会话内永久允许某条规则/目录"。
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

    /// Session-level "always allow" returns normalized updatedPermissions entries.
    var suggestionPayloads: [Data] {
        switch self {
        case .suggestion(let suggestion):
            return suggestion.resolvedPayloads
        default:
            return []
        }
    }
}

/// 一条"会话级永久允许"建议。`resolvedPayloads` 是已经规范化好的 JSON 片段，
/// 由 hook 端原样写入 Claude Code 的 `updatedPermissions`，避免渲染层去拼协议。
struct PermissionSuggestion: Identifiable, Equatable {
    enum Kind: String {
        case addRules
        case addDirectories
    }

    let id = UUID()
    let kind: Kind
    let behavior: PermissionBehavior
    let label: String
    /// Normalized updatedPermissions entries serialized as JSON Data.
    let resolvedPayloads: [Data]

    static func == (lhs: PermissionSuggestion, rhs: PermissionSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

/// 一条权限气泡需要展示的全部内容。
/// `toolInputHash` 与 `BubbleStack.countMatching` / `dismissBubbleMatchingTerminalApproval`
/// 配套使用，用于跨 PermissionRequest 与 /state 通知做精准去重。
struct PermissionBubbleContent {
    let sessionId: String
    let toolName: String
    let toolInput: String
    let toolInputHash: String?
    let suggestions: [PermissionSuggestion]

    /// 把 hook 端 POST 的 JSON body 解析成结构化内容。
    /// 字段缺失或类型不对都会回 nil，让 HTTPServer 直接 400，避免渲染半残气泡。
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
        let toolInputHash: String? = {
            guard let raw = payload["tool_input"] else {
                return nil
            }
            let data = (try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])) ?? Data()
            return PermissionMatchKey.hashRawJSON(data)
        }()
        let suggestions = decodeSuggestions(from: payload["permission_suggestions"])

        return PermissionBubbleContent(
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            toolInputHash: toolInputHash,
            suggestions: suggestions
        )
    }

    /// BubbleStack 在 SwiftUI 真正测量出高度前用来做布局预占位。
    /// 估算保守一些，实际高度回来后会通过 onContentHeightChanged 精修。
    var estimatedHeight: CGFloat {
        // The session-level suggestion is a single extra button.
        // Base: ~160 for tool pill + input preview + button row + padding.
        let baseHeight: CGFloat = 170
        let suggestionRowHeight: CGFloat = suggestions.isEmpty ? 0 : 37
        return baseHeight + suggestionRowHeight
    }

    /// 把 hook 端送来的多条原始 suggestion 折叠成"本 session 始终允许"的一条按钮。
    /// 内部按 type 分两类：addRules（具体工具+rule）与 addDirectories（目录白名单）。
    /// 各自做去重，最终只输出一条建议——气泡 UI 上只会显示一个 "Always allow" 按钮，
    /// 但点击后 hook 端会把所有规则一次性写入 session 配置。
    private static func decodeSuggestions(from rawValue: Any?) -> [PermissionSuggestion] {
        guard let rawSuggestions = rawValue as? [[String: Any]] else {
            return []
        }

        var seenPayloads = Set<Data>()
        var resolvedPayloads: [Data] = []
        var seenRules = Set<Data>()
        var sessionRules: [[String: Any]] = []
        var seenDirectories = Set<String>()
        var sessionDirectories: [String] = []

        for rawSuggestion in rawSuggestions {
            guard let type = rawSuggestion["type"] as? String else {
                continue
            }

            switch type {
            case PermissionSuggestion.Kind.addRules.rawValue:
                guard
                    let rawBehavior = rawSuggestion["behavior"] as? String,
                    let behavior = PermissionBehavior(rawValue: rawBehavior),
                    behavior == .allow
                else {
                    continue
                }

                for rule in normalizedAddRules(from: rawSuggestion) {
                    guard let ruleData = canonicalJSONData(rule),
                          seenRules.insert(ruleData).inserted else {
                        continue
                    }
                    sessionRules.append(rule)
                }
            case PermissionSuggestion.Kind.addDirectories.rawValue:
                if let rawBehavior = rawSuggestion["behavior"] as? String,
                   PermissionBehavior(rawValue: rawBehavior) != .allow {
                    continue
                }

                for directory in normalizedDirectories(from: rawSuggestion) where seenDirectories.insert(directory).inserted {
                    sessionDirectories.append(directory)
                }
            default:
                continue
            }
        }

        if !sessionRules.isEmpty {
            let resolvedPayload: [String: Any] = [
                "type": PermissionSuggestion.Kind.addRules.rawValue,
                "destination": "session",
                "behavior": PermissionBehavior.allow.rawValue,
                "rules": sessionRules,
            ]
            if let payloadData = canonicalJSONData(resolvedPayload),
               seenPayloads.insert(payloadData).inserted {
                resolvedPayloads.append(payloadData)
            }
        }

        if !sessionDirectories.isEmpty {
            let resolvedPayload: [String: Any] = [
                "type": PermissionSuggestion.Kind.addDirectories.rawValue,
                "destination": "session",
                "directories": sessionDirectories,
            ]
            if let payloadData = canonicalJSONData(resolvedPayload),
               seenPayloads.insert(payloadData).inserted {
                resolvedPayloads.append(payloadData)
            }
        }

        guard !resolvedPayloads.isEmpty else {
            return []
        }

        return [
            PermissionSuggestion(
                kind: sessionRules.isEmpty ? .addDirectories : .addRules,
                behavior: .allow,
                label: "Always allow in this session",
                resolvedPayloads: resolvedPayloads
            ),
        ]
    }

    private static func normalizedAddRules(from raw: [String: Any]) -> [[String: Any]] {
        if let rawRules = raw["rules"] as? [[String: Any]] {
            return rawRules.compactMap(normalizedRule)
        }

        return normalizedRule(raw).map { [$0] } ?? []
    }

    private static func normalizedRule(_ rawRule: [String: Any]) -> [String: Any]? {
        guard let toolName = normalizedString(rawRule["toolName"] as? String) else {
            return nil
        }

        var rule: [String: Any] = ["toolName": toolName]
        if let ruleContent = normalizedString(rawRule["ruleContent"] as? String) {
            rule["ruleContent"] = ruleContent
        }
        return rule
    }

    private static func normalizedDirectories(from raw: [String: Any]) -> [String] {
        guard let directories = raw["directories"] as? [String] else {
            return []
        }

        return directories.compactMap(normalizedString)
    }

    /// 用 sortedKeys 输出的紧凑 JSON 作为去重 key，避免 dict 顺序不同导致重复条目漏过。
    private static func canonicalJSONData(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    /// 把任意 tool_input 转为人类可读的多行字符串供气泡展示。
    /// 字符串原样、对象 / 数组按 prettyPrinted JSON 输出，其它退化为 description。
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

/// 权限气泡的 SwiftUI 视图。
/// 单击 input 区域可在折叠 / 展开（带 ScrollView）之间切换，
/// 高度变化通过 `onContentHeightChanged` 反馈给 BubbleWindow 让外框跟着伸缩。
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

/// 简单的横向流式布局：按钮放不下当前行就换行。
/// macOS 13 以下没有 Layout 协议，调用方退回到 HStack。
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
