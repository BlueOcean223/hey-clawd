import Foundation

/// 解析后的 `SVGDocument` 的 LRU 缓存。
///
/// 状态机在切换状态时会反复加载同样几张 SVG（idle/working/sleeping…），
/// 每次重新跑一遍 `SVGParser` 既慢又会触发 CALayer 重建，
/// 因此把解析结果按文件名缓存下来。容量按观察到的活跃状态数取 8——
/// 略大于常驻状态集合，又不至于把所有 mini-* 一次性塞进内存。
@MainActor
final class SVGDocumentCache {
    static let shared = SVGDocumentCache()

    private var cache: [String: SVGDocument] = [:]
    /// 访问顺序队列，越靠前越久未使用；淘汰时从队首移除。
    private var accessOrder: [String] = []
    private let capacity = 8

    private init() {}

    func get(_ key: String) -> SVGDocument? {
        guard let document = cache[key] else {
            return nil
        }

        touch(key)
        return document
    }

    func set(_ key: String, _ document: SVGDocument) {
        cache[key] = document
        touch(key)

        // 超过容量上限时移除最久未访问的条目，保持稳态内存占用。
        guard cache.count > capacity, let leastRecentlyUsedKey = accessOrder.first else {
            return
        }

        cache.removeValue(forKey: leastRecentlyUsedKey)
        accessOrder.removeFirst()
    }

    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// 把 key 移到队尾标记为最近访问；存在则先移除，避免重复条目导致淘汰错位。
    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}
