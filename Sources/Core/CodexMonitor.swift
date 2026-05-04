import Foundation
import Darwin

/// Codex CLI 没有 hook 接口，只能反向解析其 JSONL 日志获取事件。
/// 本结构是把日志条目映射成 StateMachine 能消费的状态更新。
struct CodexStateUpdate: Sendable {
    let state: PetState
    let sessionId: String
    let event: String
    let cwd: String?
    let agentId: String
}

/// 监视 `~/.codex` 下 Codex CLI 的会话日志（JSONL）并把事件转成桌宠状态。
///
/// 工作流：
/// - 启动时扫描最近 2 天内修改过的会话文件，挂上 `DispatchSourceFileSystemObject` 监听；
/// - 文件每次写入触发 1.5s 防抖读取，把新增字节按行解析；
/// - 保留状态快照到 `previouslyTrackedStates`，让被 prune 出去的文件再次活跃时能续接。
///
/// actor 是因为 DispatchSource 回调走 utility 队列，需要安全切回管理状态的隔离域。
actor CodexMonitor {
    private enum EventMapping {
        case direct(PetState)
        case turnEnd
        case ignored
    }

    /// 文件被 prune 后保存的最少状态：再启用时从同一 offset 续读，避免重复触发已处理过的事件。
    private struct SavedTrackingState {
        let offset: UInt64
        let partial: String
        let cwd: String?
        let hadToolUse: Bool
    }

    /// 单个被监视的 JSONL 文件的所有 mutable 状态。
    /// `partial` 暂存"读到一半的不完整行"，`hadToolUse` 决定 turn_end 该回 idle 还是 attention。
    private final class TrackedFile {
        let sessionId: String
        let fileURL: URL
        let fileHandle: FileHandle
        let source: DispatchSourceFileSystemObject
        var debounceTask: Task<Void, Never>?
        var offset: UInt64 = 0
        var partial = ""
        var cwd: String?
        var lastEventAt = Date()
        var lastState: PetState?
        var lastEvent: String?
        var hadToolUse = false
        var shouldDiscardFirstLine = false

        init(
            sessionId: String,
            fileURL: URL,
            fileHandle: FileHandle,
            source: DispatchSourceFileSystemObject
        ) {
            self.sessionId = sessionId
            self.fileURL = fileURL
            self.fileHandle = fileHandle
            self.source = source
        }
    }

    /// 周期性重新扫描会话目录，发现新文件。
    private static let scanInterval: TimeInterval = 1.5
    /// DispatchSource 触发后的防抖：写入往往是连续多次，等 1.5s 再读避免反复 IO。
    private static let readDebounce: TimeInterval = 1.5
    /// 超过这段时间无更新的文件被视作"陈旧"，从活跃 watch 集合中移除以释放 fd。
    private static let staleInterval: TimeInterval = 300
    /// 启动时只挂 watch 距今 2 分钟内动过的文件，旧文件按需懒加载。
    private static let recentFileWindow: TimeInterval = 120
    /// 历史扫描窗口：超过 2 天没动的会话直接忽略。
    private static let historicalLookbackDays = 2
    /// 同时 watch 的文件数上限，防止极端情况下打开过多 fd。
    private static let maxTrackedFiles = 50
    /// `previouslyTrackedStates` 的容量上限；LRU 风格淘汰最旧的快照。
    private static let maxSavedStates = 200
    /// 单条 JSONL 行最大缓冲字节，防止恶意/损坏文件导致 partial 无限增长。
    private static let maxPartialBytes = 65_536
    /// 首次挂载时只读取最后 256KB，避开历史日志全量解析。
    private static let maxInitialReadBytes: UInt64 = 256 * 1024
    private static let readChunkBytes = 64 * 1024
    // DispatchSource runs on a utility queue, then hops back into the actor for debounced reads.
    private static let watchQueue = DispatchQueue(label: "hey-clawd.codex-monitor", qos: .utility)
    /// Codex JSONL 事件 → 桌宠状态的映射表。`turnEnd` 表示一个 turn 结束，
    /// 具体回 idle 还是 attention 由本轮是否调用过工具决定（见 `applyTurnEnd`）。
    private static let eventMap: [String: EventMapping] = [
        "session_meta": .direct(.idle),
        "event_msg:task_started": .direct(.thinking),
        "event_msg:user_message": .direct(.thinking),
        "event_msg:agent_message": .ignored,
        "response_item:function_call": .direct(.working),
        "response_item:custom_tool_call": .direct(.working),
        "response_item:web_search_call": .direct(.working),
        "event_msg:task_complete": .turnEnd,
        "event_msg:context_compacted": .direct(.sweeping),
        "event_msg:turn_aborted": .direct(.idle),
    ]

    private let agentId = "codex"
    private let homeDirectoryURL: URL
    private var trackedFiles: [URL: TrackedFile] = [:]
    private var scanTask: Task<Void, Never>?
    private var previouslyTrackedStates: [URL: SavedTrackingState] = [:]
    private var lastPrunedDate: Date?

    var onStateUpdate: (@MainActor @Sendable (CodexStateUpdate) -> Void)?

    init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectoryURL = homeDirectoryURL
    }

    func start() {
        guard scanTask == nil else {
            return
        }

        let now = Date()
        scanForSessionFiles(referenceTime: now)
        scanTask = Task { [weak self] in
            await self?.runScanLoop()
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        let urls = Array(trackedFiles.keys)
        for url in urls {
            stopTracking(fileURL: url, emitSessionEnd: false)
        }
        previouslyTrackedStates.removeAll()
    }

    func setOnStateUpdate(_ handler: @escaping @MainActor @Sendable (CodexStateUpdate) -> Void) {
        onStateUpdate = handler
    }

    func scan(referenceTime: Date = Date()) {
        scanForSessionFiles(referenceTime: referenceTime)
    }

    func expireStaleFiles(referenceTime: Date = Date()) {
        cleanStaleFiles(referenceTime: referenceTime)
    }

    private var baseDirectoryURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private func runScanLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.scanInterval * 1_000_000_000))
            guard !Task.isCancelled else {
                break
            }

            let now = Date()
            scanForSessionFiles(referenceTime: now)
        }
    }

    private func scanForSessionFiles(referenceTime now: Date) {
        let fileManager = FileManager.default

        for directoryURL in candidateSessionDirectories(relativeTo: now) {
            guard let fileURLs = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for fileURL in fileURLs {
                let fileName = fileURL.lastPathComponent
                guard isRolloutLog(named: fileName) else {
                    continue
                }

                if trackedFiles[fileURL] != nil {
                    continue
                }

                if trackedFiles.count >= Self.maxTrackedFiles {
                    cleanStaleFiles(referenceTime: now)
                    if trackedFiles.count >= Self.maxTrackedFiles {
                        return
                    }
                }

                guard shouldTrackNewFile(at: fileURL, referenceTime: now) else {
                    continue
                }

                startTracking(fileURL: fileURL, fileName: fileName)
            }
        }

        cleanStaleFiles(referenceTime: now)
        pruneStaleOffsets(candidateDirectories: candidateSessionDirectories(relativeTo: now))
    }

    private func candidateSessionDirectories(relativeTo now: Date) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        let dayRange = 0 ... Self.historicalLookbackDays

        return dayRange.compactMap { daysAgo in
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else {
                return nil
            }

            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard
                let year = components.year,
                let month = components.month,
                let day = components.day
            else {
                return nil
            }

            return baseDirectoryURL
                .appendingPathComponent(String(year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private func isRolloutLog(named fileName: String) -> Bool {
        fileName.hasPrefix("rollout-") && fileName.hasSuffix(".jsonl")
    }

    private func shouldTrackNewFile(at fileURL: URL, referenceTime: Date) -> Bool {
        guard
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
            let modifiedAt = values.contentModificationDate
        else {
            return false
        }

        return referenceTime.timeIntervalSince(modifiedAt) <= Self.recentFileWindow
    }

    private func startTracking(fileURL: URL, fileName: String) {
        guard let sessionSuffix = extractSessionId(from: fileName) else {
            return
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }

        let watchFD = open(fileURL.path, O_EVTONLY)
        guard watchFD >= 0 else {
            try? fileHandle.close()
            return
        }

        // 新 rollout 文件先补读尾部上下文，后续再用 vnode write 追踪增量。
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: .write,
            queue: Self.watchQueue
        )

        let tracked = TrackedFile(
            sessionId: "\(agentId):\(sessionSuffix)",
            fileURL: fileURL,
            fileHandle: fileHandle,
            source: source
        )
        let restoredSavedState = previouslyTrackedStates.removeValue(forKey: fileURL)
        if let savedState = restoredSavedState {
            tracked.offset = savedState.offset
            tracked.partial = savedState.partial
            tracked.cwd = savedState.cwd
            tracked.hadToolUse = savedState.hadToolUse
        } else {
            bootstrapExistingFile(tracked)
        }

        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            Task {
                await self.scheduleRead(for: fileURL)
            }
        }

        source.setCancelHandler {
            close(watchFD)
        }

        trackedFiles[fileURL] = tracked
        source.resume()
        if restoredSavedState != nil {
            readNewLines(from: fileURL)
        }
    }

    private func scheduleRead(for fileURL: URL) {
        guard let tracked = trackedFiles[fileURL] else {
            return
        }

        tracked.debounceTask?.cancel()
        tracked.debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readDebounce * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            await self?.readNewLines(from: fileURL)
        }
    }

    private func readNewLines(from fileURL: URL) {
        guard let tracked = trackedFiles[fileURL] else {
            return
        }

        let fileSize = currentFileSize(for: fileURL)
        guard fileSize >= tracked.offset else {
            tracked.offset = 0
            tracked.partial = ""
            tracked.cwd = nil
            tracked.hadToolUse = false
            tracked.lastState = nil
            tracked.shouldDiscardFirstLine = false
            return
        }

        guard fileSize > tracked.offset else {
            return
        }

        do {
            tracked.offset = try consumeFileChunks(
                from: tracked.fileHandle,
                startingAt: tracked.offset,
                endingAt: fileSize,
                tracked: tracked,
                discardingFirstLine: tracked.shouldDiscardFirstLine,
                emitUpdates: true
            )
            tracked.shouldDiscardFirstLine = false
        } catch {
            stopTracking(fileURL: fileURL, emitSessionEnd: false)
        }
    }

    private func consume(
        data: Data,
        tracked: TrackedFile,
        discardingFirstLine: Bool = false,
        emitUpdates: Bool = true
    ) {
        let text = tracked.partial + String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        if let remainder = lines.last {
            let remainderString = String(remainder)
            tracked.partial = remainderString.utf8.count > Self.maxPartialBytes ? "" : remainderString
        } else {
            tracked.partial = ""
        }

        let completeLines = discardingFirstLine ? lines.dropLast().dropFirst() : lines.dropLast()
        for line in completeLines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            process(line: String(line), tracked: tracked, emitUpdates: emitUpdates)
        }
    }

    private struct ParsedLine {
        let type: String
        let key: String
        let payload: [String: Any]?
    }

    private func process(line: String, tracked: TrackedFile, emitUpdates: Bool = true) {
        guard let parsedLine = parse(line: line) else {
            return
        }

        if parsedLine.type == "session_meta" {
            tracked.cwd = parsedLine.payload?["cwd"] as? String
        }

        guard let mapping = Self.eventMap[parsedLine.key] else {
            return
        }

        switch mapping {
        case .ignored:
            return
        case .direct(let state):
            if parsedLine.key == "event_msg:task_started" {
                tracked.hadToolUse = false
            }
            // 只要这一轮真的发起过工具调用，task_complete 就该落到 attention。
            if parsedLine.key == "response_item:function_call" ||
                parsedLine.key == "response_item:custom_tool_call" ||
                parsedLine.key == "response_item:web_search_call"
            {
                tracked.hadToolUse = true
            }
            emit(state: state, event: parsedLine.key, tracked: tracked, notify: emitUpdates)
        case .turnEnd:
            let resolvedState: PetState = tracked.hadToolUse ? .attention : .idle
            tracked.hadToolUse = false
            emit(state: resolvedState, event: parsedLine.key, tracked: tracked, notify: emitUpdates)
        }
    }

    private func emit(state: PetState, event: String, tracked: TrackedFile, notify: Bool = true) {
        if state == .working, tracked.lastState == .working {
            return
        }

        tracked.lastState = state
        tracked.lastEvent = event
        tracked.lastEventAt = Date()
        guard notify else {
            return
        }
        publishCurrentState(for: tracked)
    }

    private func publishCurrentState(for tracked: TrackedFile) {
        guard let state = tracked.lastState, let event = tracked.lastEvent else {
            return
        }

        let update = CodexStateUpdate(
            state: state,
            sessionId: tracked.sessionId,
            event: event,
            cwd: tracked.cwd,
            agentId: agentId
        )
        let callback = onStateUpdate
        Task { @MainActor in
            callback?(update)
        }
    }

    private func bootstrapExistingFile(_ tracked: TrackedFile) {
        let fileSize = currentFileSize(for: tracked.fileURL)
        guard fileSize > 0 else {
            return
        }

        let startOffset = initialBootstrapOffset(for: tracked, fileSize: fileSize)

        do {
            tracked.offset = try consumeFileChunks(
                from: tracked.fileHandle,
                startingAt: startOffset,
                endingAt: fileSize,
                tracked: tracked,
                discardingFirstLine: startOffset > 0,
                emitUpdates: false
            )
            tracked.shouldDiscardFirstLine = false
            publishCurrentState(for: tracked)
        } catch {
            tracked.offset = fileSize
            tracked.partial = ""
            tracked.hadToolUse = false
            tracked.shouldDiscardFirstLine = false
        }
    }

    private func initialBootstrapOffset(for tracked: TrackedFile, fileSize: UInt64) -> UInt64 {
        guard fileSize > Self.maxInitialReadBytes else {
            return 0
        }

        var startOffset = fileSize - Self.maxInitialReadBytes

        while true {
            let readLength = min(Self.maxInitialReadBytes, fileSize - startOffset)
            guard let data = try? readData(from: tracked.fileHandle, offset: startOffset, length: readLength) else {
                return 0
            }

            if containsTaskStartedBoundary(in: data, discardingFirstLine: startOffset > 0) {
                return startOffset
            }

            guard startOffset > 0 else {
                return 0
            }

            startOffset = startOffset > Self.maxInitialReadBytes ? startOffset - Self.maxInitialReadBytes : 0
        }
    }

    private func readData(from fileHandle: FileHandle, offset: UInt64, length: UInt64) throws -> Data {
        try fileHandle.seek(toOffset: offset)
        let readCount = Int(min(length, UInt64(Int.max)))
        return try fileHandle.read(upToCount: readCount) ?? Data()
    }

    private func consumeFileChunks(
        from fileHandle: FileHandle,
        startingAt startOffset: UInt64,
        endingAt endOffset: UInt64,
        tracked: TrackedFile,
        discardingFirstLine: Bool,
        emitUpdates: Bool
    ) throws -> UInt64 {
        try fileHandle.seek(toOffset: startOffset)

        var nextOffset = startOffset
        var shouldDiscardFirstLine = discardingFirstLine

        while nextOffset < endOffset {
            let remaining = endOffset - nextOffset
            let readCount = Int(min(UInt64(Self.readChunkBytes), remaining))
            guard let data = try fileHandle.read(upToCount: readCount), !data.isEmpty else {
                break
            }

            nextOffset += UInt64(data.count)
            consume(
                data: data,
                tracked: tracked,
                discardingFirstLine: shouldDiscardFirstLine,
                emitUpdates: emitUpdates
            )
            shouldDiscardFirstLine = false
        }

        return nextOffset
    }

    private func containsTaskStartedBoundary(in data: Data, discardingFirstLine: Bool) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let completeLines = discardingFirstLine ? lines.dropLast().dropFirst() : lines.dropLast()

        for line in completeLines.reversed() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            if parse(line: String(line))?.key == "event_msg:task_started" {
                return true
            }
        }

        return false
    }

    private func parse(line: String) -> ParsedLine? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return nil
        }

        let payload = object["payload"] as? [String: Any]
        let subtype = payload?["type"] as? String
        let key = subtype.flatMap { $0.isEmpty ? nil : "\(type):\($0)" } ?? type
        return ParsedLine(type: type, key: key, payload: payload)
    }

    private func cleanStaleFiles(referenceTime: Date) {
        for (fileURL, tracked) in trackedFiles {
            guard referenceTime.timeIntervalSince(tracked.lastEventAt) > Self.staleInterval else {
                continue
            }

            stopTracking(fileURL: fileURL, emitSessionEnd: true)
        }
    }

    private func pruneStaleOffsets(candidateDirectories: [URL]) {
        guard !previouslyTrackedStates.isEmpty else {
            return
        }

        let now = Date()
        if let lastPruned = lastPrunedDate,
           Calendar.current.isDate(lastPruned, inSameDayAs: now) {
            return
        }

        lastPrunedDate = now
        let validPrefixes = candidateDirectories.map { $0.path }
        previouslyTrackedStates = previouslyTrackedStates.filter { url, _ in
            validPrefixes.contains { url.path.hasPrefix($0) }
        }
    }

    private func stopTracking(fileURL: URL, emitSessionEnd: Bool) {
        guard let tracked = trackedFiles.removeValue(forKey: fileURL) else {
            return
        }

        previouslyTrackedStates[fileURL] = SavedTrackingState(
            offset: tracked.offset,
            partial: tracked.partial,
            cwd: tracked.cwd,
            hadToolUse: tracked.hadToolUse
        )

        if previouslyTrackedStates.count > Self.maxSavedStates {
            let oldest = previouslyTrackedStates.keys.sorted { $0.path < $1.path }.first
            if let oldest {
                previouslyTrackedStates.removeValue(forKey: oldest)
            }
        }

        tracked.debounceTask?.cancel()
        tracked.debounceTask = nil
        tracked.source.cancel()
        try? tracked.fileHandle.close()

        if emitSessionEnd {
            let update = CodexStateUpdate(
                state: .idle,
                sessionId: tracked.sessionId,
                event: "SessionEnd",
                cwd: tracked.cwd,
                agentId: agentId
            )
            let callback = onStateUpdate
            Task { @MainActor in
                callback?(update)
            }
        }
    }

    private func currentFileSize(for fileURL: URL) -> UInt64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }

        return size.uint64Value
    }

    private func extractSessionId(from fileName: String) -> String? {
        let base = fileName.replacingOccurrences(of: ".jsonl", with: "")
        let parts = base.split(separator: "-")
        guard parts.count >= 6 else {
            return nil
        }

        return parts.suffix(5).joined(separator: "-")
    }
}
