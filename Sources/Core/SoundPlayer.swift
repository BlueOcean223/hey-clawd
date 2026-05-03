import AVFoundation
import Foundation

/// 一次性提示音播放器，主要服务于 `attention`/`notification` 这类一次性状态。
///
/// 使用单例 + `AVAudioPlayer` 缓存，避免每次都从磁盘解码；
/// 同时引入冷却时间，防止短时间高频的 hook 事件叠加成吵闹的"机关枪音效"。
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    /// 两次播放之间的最小间隔；即使有更多请求进来也直接丢弃，保护用户耳朵。
    private static let cooldown: TimeInterval = 10

    private var cache: [String: AVAudioPlayer] = [:]
    private var lastPlayTime: Date = .distantPast

    private init() {}

    /// 按文件名播放 `Resources/sounds/<name>` 中的提示音。
    /// 静音/勿扰/冷却任意一项命中都会静默跳过，调用方不需关心是否真的发声。
    func play(_ name: String) {
        guard !Preferences.shared.soundMuted else {
            return
        }

        guard !Preferences.shared.doNotDisturbEnabled else {
            return
        }

        guard Date().timeIntervalSince(lastPlayTime) > Self.cooldown else {
            return
        }

        guard let player = cachedPlayer(named: name) else {
            return
        }

        // 同一播放器复用时必须重置进度，否则上一段未播完会被截断后立即结束。
        player.currentTime = 0
        if player.play() {
            lastPlayTime = Date()
        }
    }

    /// 命中缓存直接返回；首次访问触发解码并 `prepareToPlay`，之后播放零延迟。
    private func cachedPlayer(named name: String) -> AVAudioPlayer? {
        if let player = cache[name] {
            return player
        }

        guard let player = loadPlayer(named: name) else {
            return nil
        }

        player.prepareToPlay()
        cache[name] = player
        return player
    }

    private func loadPlayer(named name: String) -> AVAudioPlayer? {
        guard let resourcesURL = bundledResourcesURL() else {
            return nil
        }

        let soundURL = resourcesURL
            .appendingPathComponent("sounds", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)

        guard FileManager.default.fileExists(atPath: soundURL.path) else {
            return nil
        }

        return try? AVAudioPlayer(contentsOf: soundURL)
    }

    /// 资源查找规则和 SVG/Web 资源保持一致，兼容 Xcode app bundle 与 SPM build 两种布局。
    private func bundledResourcesURL() -> URL? {
        let fileManager = FileManager.default
        var candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Resources", isDirectory: true),
            Bundle.main.resourceURL,
        ]

#if SWIFT_PACKAGE
        candidates.insert(Bundle.module.resourceURL?.appendingPathComponent("Resources", isDirectory: true), at: 0)
        candidates.insert(Bundle.module.resourceURL, at: 1)
#endif

        for candidate in candidates.compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }

        return nil
    }
}
