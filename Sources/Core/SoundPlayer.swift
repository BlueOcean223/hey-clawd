import AppKit
import Foundation

@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private static let cooldown: TimeInterval = 10

    private var cache: [String: NSSound] = [:]
    private var lastPlayTime: Date = .distantPast

    private init() {}

    func play(_ name: String) {
        // 音效和 DND 都是全局偏好，入口统一在这里拦，调用方只关心“现在该播什么”。
        guard !Preferences.shared.soundMuted else {
            return
        }

        guard !Preferences.shared.doNotDisturbEnabled else {
            return
        }

        // 统一 cooldown，避免 attention / notification 高频来回切换时刷屏。
        guard Date().timeIntervalSince(lastPlayTime) > Self.cooldown else {
            return
        }

        guard let sound = cachedSound(named: name) else {
            return
        }

        if sound.play() {
            lastPlayTime = Date()
        }
    }

    private func cachedSound(named name: String) -> NSSound? {
        if let sound = cache[name] {
            return sound
        }

        guard let sound = loadSound(named: name) else {
            return nil
        }

        cache[name] = sound
        return sound
    }

    private func loadSound(named name: String) -> NSSound? {
        guard let resourcesURL = bundledResourcesURL() else {
            return nil
        }

        let soundURL = resourcesURL
            .appendingPathComponent("sounds", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)

        guard FileManager.default.fileExists(atPath: soundURL.path) else {
            return nil
        }

        return NSSound(contentsOf: soundURL, byReference: false)
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
