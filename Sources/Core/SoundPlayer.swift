import AVFoundation
import Foundation

@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private static let cooldown: TimeInterval = 10

    private var cache: [String: AVAudioPlayer] = [:]
    private var lastPlayTime: Date = .distantPast

    private init() {}

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

        player.currentTime = 0
        if player.play() {
            lastPlayTime = Date()
        }
    }

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
