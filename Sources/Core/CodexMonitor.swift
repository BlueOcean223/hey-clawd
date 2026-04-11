import Foundation
import Darwin

struct CodexStateUpdate: Sendable {
    let state: PetState
    let sessionId: String
    let event: String
    let cwd: String?
    let agentId: String
}

actor CodexMonitor {
    private enum EventMapping {
        case direct(PetState)
        case turnEnd
        case ignored
    }

    private struct SavedTrackingState {
        let offset: UInt64
        let partial: String
        let cwd: String?
        let hadToolUse: Bool
    }

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

    private static let scanInterval: TimeInterval = 1.5
    private static let readDebounce: TimeInterval = 1.5
    private static let staleInterval: TimeInterval = 300
    private static let recentFileWindow: TimeInterval = 120
    private static let historicalLookbackDays = 2
    private static let maxTrackedFiles = 50
    private static let maxSavedStates = 200
    private static let maxPartialBytes = 65_536
    private static let maxInitialReadBytes: UInt64 = 256 * 1024
    // DispatchSource runs on a utility queue, then hops back into the actor for debounced reads.
    private static let watchQueue = DispatchQueue(label: "hey-clawd.codex-monitor", qos: .utility)
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
            // Blocking I/O on the actor's cooperative executor. Acceptable for small
            // incremental reads of Codex JSONL logs. For large files, consider moving
            // file reads to a DispatchQueue and bridging back via continuation.
            try tracked.fileHandle.seek(toOffset: tracked.offset)
            let data = tracked.fileHandle.readDataToEndOfFile()
            tracked.offset = fileSize
            consume(data: data, tracked: tracked, discardingFirstLine: tracked.shouldDiscardFirstLine)
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
            try tracked.fileHandle.seek(toOffset: startOffset)
            let data = tracked.fileHandle.readDataToEndOfFile()
            consume(
                data: data,
                tracked: tracked,
                discardingFirstLine: startOffset > 0,
                emitUpdates: false
            )
            tracked.offset = fileSize
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
            guard let data = try? readData(from: tracked.fileHandle, offset: startOffset) else {
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

    private func readData(from fileHandle: FileHandle, offset: UInt64) throws -> Data {
        try fileHandle.seek(toOffset: offset)
        return fileHandle.readDataToEndOfFile()
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
