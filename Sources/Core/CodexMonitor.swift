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
        var hadToolUse = false

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
    private static let maxTrackedFiles = 50
    private static let maxPartialBytes = 65_536
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

    var onStateUpdate: (@Sendable (CodexStateUpdate) -> Void)?

    init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectoryURL = homeDirectoryURL
    }

    func start() {
        guard scanTask == nil else {
            return
        }

        scanForSessionFiles()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.scanInterval * 1_000_000_000))
                guard !Task.isCancelled else {
                    break
                }
                await self?.scanForSessionFiles()
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        let urls = Array(trackedFiles.keys)
        for url in urls {
            stopTracking(fileURL: url, emitSleeping: false)
        }
    }

    func setOnStateUpdate(_ handler: @escaping @Sendable (CodexStateUpdate) -> Void) {
        onStateUpdate = handler
    }

    private var baseDirectoryURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private func scanForSessionFiles() {
        let fileManager = FileManager.default
        let now = Date()

        for directoryURL in candidateSessionDirectories(relativeTo: now) {
            guard let fileNames = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
                continue
            }

            for fileName in fileNames where isRolloutLog(named: fileName) {
                let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
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
    }

    private func candidateSessionDirectories(relativeTo now: Date) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)

        return (0 ... 2).compactMap { daysAgo in
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
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let modifiedAt = attributes[.modificationDate] as? Date
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

        // 新 rollout 文件先补读当前内容，后续再用 vnode write 追踪增量。
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
        readNewLines(from: fileURL)
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
            return
        }

        guard fileSize > tracked.offset else {
            return
        }

        do {
            try tracked.fileHandle.seek(toOffset: tracked.offset)
            let data = tracked.fileHandle.readDataToEndOfFile()
            tracked.offset = fileSize
            consume(data: data, tracked: tracked)
        } catch {
            stopTracking(fileURL: fileURL, emitSleeping: false)
        }
    }

    private func consume(data: Data, tracked: TrackedFile) {
        let text = tracked.partial + String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        if let remainder = lines.last {
            let remainderString = String(remainder)
            tracked.partial = remainderString.utf8.count > Self.maxPartialBytes ? "" : remainderString
        } else {
            tracked.partial = ""
        }

        for line in lines.dropLast() where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            process(line: String(line), tracked: tracked)
        }
    }

    private func process(line: String, tracked: TrackedFile) {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return
        }

        let payload = object["payload"] as? [String: Any]
        let subtype = payload?["type"] as? String
        let key = subtype.flatMap { $0.isEmpty ? nil : "\(type):\($0)" } ?? type

        if type == "session_meta" {
            tracked.cwd = payload?["cwd"] as? String
        }

        guard let mapping = Self.eventMap[key] else {
            return
        }

        switch mapping {
        case .ignored:
            return
        case .direct(let state):
            if key == "event_msg:task_started" {
                tracked.hadToolUse = false
            }
            // 只要这一轮真的发起过工具调用，task_complete 就该落到 attention。
            if key == "response_item:function_call" ||
                key == "response_item:custom_tool_call" ||
                key == "response_item:web_search_call"
            {
                tracked.hadToolUse = true
            }
            emit(state: state, event: key, tracked: tracked)
        case .turnEnd:
            let resolvedState: PetState = tracked.hadToolUse ? .attention : .idle
            tracked.hadToolUse = false
            emit(state: resolvedState, event: key, tracked: tracked)
        }
    }

    private func emit(state: PetState, event: String, tracked: TrackedFile) {
        if state == .working, tracked.lastState == .working {
            return
        }

        tracked.lastState = state
        tracked.lastEventAt = Date()
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

    private func cleanStaleFiles(referenceTime: Date) {
        for (fileURL, tracked) in trackedFiles {
            guard referenceTime.timeIntervalSince(tracked.lastEventAt) > Self.staleInterval else {
                continue
            }

            stopTracking(fileURL: fileURL, emitSleeping: true)
        }
    }

    private func stopTracking(fileURL: URL, emitSleeping: Bool) {
        guard let tracked = trackedFiles.removeValue(forKey: fileURL) else {
            return
        }

        tracked.debounceTask?.cancel()
        tracked.debounceTask = nil
        tracked.source.cancel()
        try? tracked.fileHandle.close()

        if emitSleeping {
            let update = CodexStateUpdate(
                state: .sleeping,
                sessionId: tracked.sessionId,
                event: "stale-cleanup",
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
