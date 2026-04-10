import Foundation

@MainActor
final class SVGDocumentCache {
    static let shared = SVGDocumentCache()

    private var cache: [String: SVGDocument] = [:]
    private var accessOrder: [String] = []
    private let capacity = 5

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

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}
