import Foundation
@preconcurrency import Network

enum PermissionBehavior: String, Sendable {
    case allow
    case deny
}

/// bubble 或快捷键做出的权限决策，附带可选的 suggestion 数据。
struct PermissionDecisionResult: Sendable {
    let behavior: PermissionBehavior
    /// 选中 suggestion 时序列化的 updatedPermissions JSON entries。
    let suggestionPayloads: [Data]

    static func simple(_ behavior: PermissionBehavior) -> PermissionDecisionResult {
        PermissionDecisionResult(behavior: behavior, suggestionPayloads: [])
    }
}

/// POST /permission 产生的挂起请求。
/// 连接保持打开，直到上层调用 respond(with:) 发送许可结果。
/// lock 保证 continuation 最多只被 resume 一次。
final class PendingPermissionRequest: @unchecked Sendable {
    let body: Data

    private let lock = NSLock()
    private var continuation: CheckedContinuation<PermissionDecisionResult, Never>?
    private var disconnectHandler: (@Sendable () -> Void)?
    private var status: RequestStatus = .pending

    private enum RequestStatus {
        case pending
        case completed
        case disconnected
    }

    init(body: Data, continuation: CheckedContinuation<PermissionDecisionResult, Never>) {
        self.body = body
        self.continuation = continuation
    }

    var isAwaitingDecision: Bool {
        lock.withLock { status == .pending }
    }

    func respond(with result: PermissionDecisionResult) {
        let continuation = lock.withLock { () -> CheckedContinuation<PermissionDecisionResult, Never>? in
            guard status == .pending else {
                return nil
            }

            status = .completed
            defer {
                self.continuation = nil
                self.disconnectHandler = nil
            }
            return self.continuation
        }

        continuation?.resume(returning: result)
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        let shouldInvokeImmediately = lock.withLock { () -> Bool in
            if status == .disconnected {
                return true
            }

            guard status == .pending else {
                return false
            }

            disconnectHandler = handler
            return false
        }

        if shouldInvokeImmediately {
            handler()
        }
    }

    func clearDisconnectHandler() {
        lock.withLock {
            disconnectHandler = nil
        }
    }

    func cancelDueToDisconnect() {
        let result = lock.withLock { () -> (CheckedContinuation<PermissionDecisionResult, Never>?, (@Sendable () -> Void)?) in
            guard status == .pending else {
                return (nil, nil)
            }

            status = .disconnected
            defer {
                self.continuation = nil
                self.disconnectHandler = nil
            }
            return (continuation, disconnectHandler)
        }

        result.0?.resume(returning: .simple(.deny))
        result.1?()
    }
}

/// NWListener 的状态回调可能触发多次（ready/failed/cancelled），
/// 用 ContinuationGate 保证 CheckedContinuation 只被 resume 一次。
private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func finish(_ result: Value, continuation: CheckedContinuation<Value, Never>) {
        let shouldResume = lock.withLock { () -> Bool in
            guard !hasResumed else {
                return false
            }

            hasResumed = true
            return true
        }

        if shouldResume {
            continuation.resume(returning: result)
        }
    }
}

private final class ConnectionPermissionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingPermission: PendingPermissionRequest?

    func attach(_ request: PendingPermissionRequest) {
        lock.withLock {
            pendingPermission = request
        }
    }

    func clear() {
        lock.withLock {
            pendingPermission = nil
        }
    }

    func cancelPendingPermission() {
        let request = lock.withLock { () -> PendingPermissionRequest? in
            defer { pendingPermission = nil }
            return pendingPermission
        }

        // /permission 还在挂起时如果客户端先断开，要同步撤掉对应气泡。
        request?.cancelDueToDisconnect()
    }
}

/// ~/.clawd/runtime.json 的结构，供 hook 脚本发现运行中的端口
private struct RuntimeConfig: Codable, Sendable {
    let app: String
    let port: Int
}

/// 基于 Network.framework 的轻量 HTTP 服务器。
/// 监听 127.0.0.1:23333-23337，绑定失败则依次尝试下一个端口，
/// 全部失败则进入 idle-only 模式（不接收 hook 事件）。
final class HTTPServer: @unchecked Sendable {
    static let defaultPort = 23_333
    static let portRange = 23_333...23_337  // 5 个候选端口

    private static let appName = "hey-clawd"
    private static let listenHost = NWEndpoint.Host("127.0.0.1")
    private static let maxRequestBytes = 532_480    // 520 KB，为 512 KB body + 头部留余量
    private static let statePayloadLimit = 1_024    // POST /state body 上限
    private static let permissionPayloadLimit = 524_288  // POST /permission body 上限 (512 KB)

    private let queue = DispatchQueue(label: "hey-clawd.http-server")
    private let lock = NSLock()

    private var listener: NWListener?
    private var port: Int?
    private var stateRequestHandler: ((Data) async -> HTTPResponse)?
    private var permissionRequestHandler: ((PendingPermissionRequest) -> Void)?

    var currentPort: Int? {
        lock.withLock { port }
    }

    func setStateRequestHandler(_ handler: ((Data) async -> HTTPResponse)?) {
        lock.withLock {
            stateRequestHandler = handler
        }
    }

    func setPermissionRequestHandler(_ handler: ((PendingPermissionRequest) -> Void)?) {
        lock.withLock {
            permissionRequestHandler = handler
        }
    }

    /// 依次尝试 portRange 内的端口，返回成功绑定的端口号。
    /// 全部失败返回 nil，此时进入 idle-only 模式（仅显示静态动画）。
    func start() async -> Int? {
        if let currentPort {
            return currentPort
        }

        for candidate in Self.portRange {
            if let activePort = await startListener(on: candidate) {
                return activePort
            }
        }

        removeRuntimeConfig()
        print("http server unavailable; running in idle-only mode")
        return nil
    }

    func stop() {
        let activeListener = lock.withLock { () -> NWListener? in
            defer {
                listener = nil
                port = nil
            }
            return listener
        }

        activeListener?.cancel()
        removeRuntimeConfig()
    }

    private func startListener(on candidatePort: Int) async -> Int? {
        let listener: NWListener

        do {
            listener = try makeListener(port: candidatePort)
        } catch {
            print("http server listener-create failed on port \(candidatePort): \(error)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let gate = ContinuationGate<Int?>()

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    guard let self, let listener else {
                        gate.finish(nil, continuation: continuation)
                        return
                    }

                    self.lock.withLock {
                        self.listener = listener
                        self.port = candidatePort
                    }

                    self.writeRuntimeConfig(port: candidatePort)
                    print("http server listening on 127.0.0.1:\(candidatePort)")
                    gate.finish(candidatePort, continuation: continuation)

                case .failed(let error):
                    print("http server bind failed on port \(candidatePort): \(error)")
                    listener?.cancel()
                    gate.finish(nil, continuation: continuation)

                case .cancelled:
                    gate.finish(nil, continuation: continuation)

                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: queue)
        }
    }

    private func makeListener(port: Int) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: Self.listenHost,
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )

        return try NWListener(using: parameters)
    }

    private func accept(_ connection: NWConnection) {
        let permissionTracker = ConnectionPermissionTracker()

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                permissionTracker.cancelPendingPermission()
            default:
                break
            }
        }

        connection.start(queue: queue)

        Task { [weak self, connection] in
            await self?.processConnection(connection, permissionTracker: permissionTracker)
        }
    }

    /// 增量读取连接数据，凑齐完整 HTTP 请求后路由处理。
    /// 每个连接只处理一个请求，响应后关闭。
    private func processConnection(_ connection: NWConnection, permissionTracker: ConnectionPermissionTracker) async {
        defer {
            connection.cancel()
        }

        var buffer = Data()

        do {
            while true {
                if let request = HTTPParser.parseRequest(buffer) {
                    // 只对 /permission 启动断连监听——/state 等短连接不需要。
                    let path = normalizedPath(from: request.path)
                    if request.method.uppercased() == "POST" && path == "/permission" {
                        monitorDisconnect(connection: connection, tracker: permissionTracker)
                    }
                    let response = await route(request, permissionTracker: permissionTracker)
                    try await send(response.serialize(), on: connection)
                    return
                }

                if buffer.count > Self.maxRequestBytes {
                    try await send(errorResponse(statusCode: 413, message: "payload too large").serialize(), on: connection)
                    return
                }

                guard let chunk = try await receiveChunk(on: connection) else {
                    return
                }

                if chunk.isEmpty {
                    continue
                }

                buffer.append(chunk)
            }
        } catch {
            print("http server connection error: \(error)")
        }
    }

    /// 路由表：
    /// - GET  /state      → 健康检查，返回 app 名称和端口
    /// - POST /state      → 状态更新，转发给 StateMachine
    /// - POST /permission → 权限请求，挂起等待用户决策
    /// - 其他             → 404
    private func route(_ request: HTTPRequest, permissionTracker: ConnectionPermissionTracker) async -> HTTPResponse {
        let path = normalizedPath(from: request.path)

        switch (request.method.uppercased(), path) {
        case ("GET", "/state"):
            return jsonResponse([
                "ok": true,
                "app": Self.appName,
                "port": currentPort ?? Self.defaultPort,
            ])

        case ("POST", "/state"):
            guard request.body.count <= Self.statePayloadLimit else {
                return errorResponse(statusCode: 413, message: "payload too large")
            }

            guard isValidJSONObjectData(request.body) else {
                return errorResponse(statusCode: 400, message: "invalid json")
            }

            guard let handler = lock.withLock({ stateRequestHandler }) else {
                return errorResponse(statusCode: 503, message: "state handler unavailable")
            }

            // 2.4 起由 AppDelegate 负责解释 /state JSON 并调用 StateMachine。
            // HTTPServer 只保留网络收包、大小限制和响应发送这些传输层职责。
            return await handler(request.body)

        case ("POST", "/permission"):
            guard request.body.count <= Self.permissionPayloadLimit else {
                return errorResponse(statusCode: 413, message: "payload too large")
            }

            guard isValidJSONObjectData(request.body) else {
                return errorResponse(statusCode: 400, message: "invalid json")
            }

            guard lock.withLock({ permissionRequestHandler }) != nil else {
                return errorResponse(statusCode: 503, message: "permission handler unavailable")
            }

            // 挂起当前连接，直到上层通过 PendingPermissionRequest.respond() 返回结果
            let result = await resolvePermission(body: request.body, permissionTracker: permissionTracker)
            return permissionResponse(result)

        default:
            return errorResponse(statusCode: 404, message: "not found")
        }
    }

    private func normalizedPath(from rawPath: String) -> String {
        String(rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    private func isValidJSONObjectData(_ data: Data) -> Bool {
        guard !data.isEmpty else {
            return false
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }

        return jsonObject is [String: Any]
    }

    private func jsonResponse(_ object: [String: Any], statusCode: Int = 200) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: defaultHeaders(contentType: "application/json"),
            body: body
        )
    }

    private func errorResponse(statusCode: Int, message: String) -> HTTPResponse {
        jsonResponse(["error": message], statusCode: statusCode)
    }

    /// Claude Code HTTP hook 要求 PermissionRequest 的响应遵循 JSON output schema：
    /// `{ hookSpecificOutput: { hookEventName, decision: { behavior, updatedPermissions? } } }`
    private func permissionResponse(_ result: PermissionDecisionResult) -> HTTPResponse {
        var decision: [String: Any] = ["behavior": result.behavior.rawValue]

        if result.behavior == .allow {
            let updatedPermissions = result.suggestionPayloads.compactMap { payload in
                try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            }
            if !updatedPermissions.isEmpty {
                decision["updatedPermissions"] = updatedPermissions
            }
        }

        return jsonResponse([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ] as [String: Any],
        ])
    }

    private func defaultHeaders(contentType: String) -> [String: String] {
        [
            "Content-Type": contentType,
            "x-clawd-server": Self.appName,
        ]
    }

    private func resolvePermission(body: Data, permissionTracker: ConnectionPermissionTracker) async -> PermissionDecisionResult {
        let handler = lock.withLock { permissionRequestHandler }

        let result = await withCheckedContinuation { continuation in
            let request = PendingPermissionRequest(body: body, continuation: continuation)
            permissionTracker.attach(request)

            if let handler {
                handler(request)
            } else {
                request.respond(with: .simple(.deny))
            }
        }

        permissionTracker.clear()
        return result
    }

    private func receiveChunk(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                    return
                }

                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: Data())
            }
        }
    }

    /// 在 /permission 挂起期间主动读取连接，检测客户端断连（EOF/RST）。
    /// TCP 半关闭不会让 NWConnection 转到 .failed，但 receive 会收到 isComplete=true。
    private func monitorDisconnect(connection: NWConnection, tracker: ConnectionPermissionTracker) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if error != nil || isComplete {
                tracker.cancelPendingPermission()
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    /// 启动时写入 ~/.clawd/runtime.json，供 hook 脚本发现可用端口。
    /// 目录不存在时自动创建。
    private func writeRuntimeConfig(port: Int) {
        let config = RuntimeConfig(app: Self.appName, port: port)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            let directoryURL = runtimeDirectoryURL()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(config)
            try data.write(to: runtimeConfigURL(), options: [.atomic])
        } catch {
            print("http server runtime-config write failed: \(error)")
        }
    }

    /// 退出时清理 runtime.json，避免残留文件误导 hook 脚本。
    private func removeRuntimeConfig() {
        do {
            let runtimeURL = runtimeConfigURL()
            if FileManager.default.fileExists(atPath: runtimeURL.path) {
                try FileManager.default.removeItem(at: runtimeURL)
            }
        } catch {
            print("http server runtime-config cleanup failed: \(error)")
        }
    }

    private func runtimeDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawd", isDirectory: true)
    }

    private func runtimeConfigURL() -> URL {
        runtimeDirectoryURL().appendingPathComponent("runtime.json", isDirectory: false)
    }
}
